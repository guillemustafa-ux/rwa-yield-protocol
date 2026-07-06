// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
// `ReentrancyGuard` (NOT the removed `ReentrancyGuardUpgradeable`, see note below) lives in the
// non-upgradeable OZ package on purpose — see the NatSpec on the contract declaration.
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {ERC4626Upgradeable} from
    "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

import {AggregatorV3Interface} from "./interfaces/AggregatorV3Interface.sol";

/// @title RwaVault — ERC-7540 async vault, UUPS upgradeable, valued by NAV oracle
/// @author RWA Yield Protocol
/// @notice The economic heart of the protocol (ARCHITECTURE.md §3.3). Depositors send the
///         underlying asset (a USDC-like ERC-20) and, in three steps — request, fulfill,
///         claim — end up holding vault shares. Unlike a plain ERC-4626, share price does
///         NOT come from the vault's own asset balance: it comes from `RwaNavFeed`, a
///         Chainlink-compatible NAV oracle for the `tBILL` synthetic RWA token the vault
///         holds. Nobody transfers yield in: the NAV rising IS the yield (accrual is purely
///         contractual, see {totalAssets}).
/// @dev Design decisions worth reading before touching this file:
///
///      1. WHY NOT `ReentrancyGuardUpgradeable`: this repo's installed OpenZeppelin
///         Upgradeable release (5.6.1) does not ship that contract — the plain,
///         non-upgradeable `ReentrancyGuard` (openzeppelin-contracts, utils/ReentrancyGuard.sol)
///         was rewritten (as of the same OZ generation) to keep its `_status` flag in an ERC-7201 namespaced slot
///         and, critically, its correctness does NOT depend on the constructor having run:
///         `_nonReentrantBefore`/`_nonReentrantAfter` only ever compare the slot against the
///         sentinel `ENTERED` value, never against `NOT_ENTERED`, so an uninitialized
///         (zero) slot behaves identically to an initialized one. OZ's own upgradeable mocks
///         (`ReentrancyMockUpgradeable`) inherit this exact contract directly for that
///         reason. It is therefore proxy-safe without an `__ReentrancyGuard_init` step.
///
///      2. WHY `AccessControlUpgradeable` roles are granted post-deploy, not in
///         `initialize`: only `DEFAULT_ADMIN_ROLE` is granted to `admin` at initialization.
///         `admin` must separately `grantRole` each of `ASSET_MANAGER_ROLE`,
///         `OPERATOR_ROLE`, `PAUSER_ROLE`, `UPGRADER_ROLE` to whichever accounts should hold
///         them. This is the "separación real" from ARCHITECTURE.md §2/§3.3: the admin
///         *appoints* operators but never operates, mirroring `RwaNavFeed`'s
///         admin/`NAV_UPDATER_ROLE` split from D1.
///
///      3. `totalAssets()` NAV accounting and why `totalClaimableRedeemAssets` is
///         SUBTRACTED (see {totalAssets} and {_freeAssetBuffer}): once `fulfillRedeem` burns
///         a controller's shares, that controller's assets have already left the pool from
///         an accounting standpoint even though the ERC-20 balance hasn't moved yet — the
///         same reasoning `AsyncVault` (yield-vault) uses. Failing to exclude them would let
///         remaining shareholders' price-per-share jump for free the instant a redeem is
///         fulfilled (double-counting: once for the departing holder's pending claim, again
///         for everyone still in the pool).
///
///      4. `investInTBill` / `divestFromTBill` operationalize the one piece of §3.3 that the
///         D1 contracts (`TBillToken`, `RwaNavFeed`) don't wire up on their own: "el
///         ASSET_MANAGER convierte el USDC en tBILL". This vault deliberately never calls
///         `TBillToken.mint`/`burn` itself — that authority lives entirely in `TBillToken`'s
///         own `ASSET_MANAGER_ROLE` (a *different* AccessControl instance, even though the
///         role identifier hashes the same), granted by TBillToken's admin to whichever
///         address actually executes the off-chain purchase/sale. This vault only exposes
///         the OTHER leg of that trade — pulling/returning the asset leg — gated by ITS OWN
///         `ASSET_MANAGER_ROLE`, capped by {_freeAssetBuffer} so the asset manager can never
///         touch money reserved for pending deposits or already-fulfilled redeem claims.
///         `tBillToken.balanceOf(vault)` is then simply trusted as a fact, read-only, never
///         written by this contract — keeping this file fully decoupled from TBillToken's
///         internals per the ownership boundary of this task. The settlement gap between
///         "asset left the vault" and "tBILL NAV reflects it" is an accepted, disclosed
///         trust assumption on `ASSET_MANAGER_ROLE`, symmetric to the trust already placed
///         in `NAV_UPDATER_ROLE` in `RwaNavFeed`.
///
///      5. Rounding always favors the vault (ARCHITECTURE.md §4): `convertToShares`/
///         `convertToAssets` (used by `fulfillDeposit`/`fulfillRedeem` to fix the settlement
///         price) inherit `ERC4626Upgradeable`'s default `Math.Rounding.Floor` in both
///         directions — fewer shares minted per asset, fewer assets paid per share. The
///         partial-claim helpers (`deposit`/`mint`/`redeem`/`withdraw` with an explicit
///         `controller`) mirror `AsyncVault`'s directions exactly: whichever side is
///         "consumed" from the claimable bucket for a partial claim rounds UP (so the
///         claimer's bucket depletes at least as fast as their proportional share), and
///         whichever side is "paid out" rounds DOWN.
///
///      6. Partial pause only (ARCHITECTURE.md §4, "pausa como DoS"): `whenNotPaused` is
///         applied ONLY to `requestDeposit`/`requestRedeem`. Every other state-changing
///         function — `fulfillDeposit`, `fulfillRedeem`, all four claim entry points,
///         `investInTBill`/`divestFromTBill`, `setOperator` — ignores `paused()` entirely.
///         A pause can slow new exposure from being taken on; it must never let `PAUSER_ROLE`
///         trap money that is already the vault's or already committed to a depositor.
contract RwaVault is
    Initializable,
    ERC4626Upgradeable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    ReentrancyGuard,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;
    using Math for uint256;

    // ------------------------------------------------------------------
    // Roles
    // ------------------------------------------------------------------

    /// @notice Gates the asset<->tBILL treasury rails ({investInTBill}/{divestFromTBill}).
    /// @dev Deliberately NOT granted to `admin` at {initialize} — see contract NatSpec point 2.
    bytes32 public constant ASSET_MANAGER_ROLE = keccak256("ASSET_MANAGER_ROLE");

    /// @notice Gates {fulfillDeposit}/{fulfillRedeem} — the only account that can settle
    ///         pending requests at the NAV/share-price prevailing at the time of the call.
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    /// @notice Gates {pause}/{unpause}.
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    /// @notice Gates {_authorizeUpgrade} — the only account that can push a new implementation.
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    // ------------------------------------------------------------------
    // Constants
    // ------------------------------------------------------------------

    /// @dev All requests in this vault use the aggregated (requestId=0) ERC-7540 model —
    ///      identical simplification to `AsyncVault`: no per-request IDs, requests for the
    ///      same controller accumulate into a single pending/claimable bucket.
    uint256 public constant REQUEST_ID = 0;

    /// @notice Maximum age (in seconds) a NAV round may have before every feed read reverts.
    /// @dev Applied on every single read of `navFeed` (there is exactly one call site,
    ///      {_latestNav}, that every other function funnels through) — never a silent stale
    ///      price. 24h matches a T-bill NAV that realistically updates at most daily.
    uint256 public constant MAX_STALENESS = 24 hours;

    // ------------------------------------------------------------------
    // Storage (regular, proxy-owned slots — every OZ upgradeable parent above uses ERC-7201
    // namespaced storage instead of sequential slots, so none of them consume slot space
    // here; `__gap` below still reserves room for a future RwaVaultV2 to append safely).
    // ------------------------------------------------------------------

    /// @notice The synthetic T-bill token this vault holds as its yield-bearing RWA leg.
    /// @dev Read-only from this contract's perspective: `RwaVault` never calls `mint`/`burn`
    ///      on it (see contract NatSpec point 4). Typed as `IERC20Metadata` because
    ///      {_tBillValueInAsset} needs its `decimals()`.
    IERC20Metadata public tBillToken;

    /// @notice The NAV oracle for `tBillToken`, consumed exactly like a Chainlink feed.
    AggregatorV3Interface public navFeed;

    // --- ERC-7540 DEPOSIT cycle state (by controller) ---
    mapping(address controller => uint256) public pendingDeposit;
    mapping(address controller => uint256) public claimableDepositAssets;
    mapping(address controller => uint256) public claimableDepositShares;

    // --- ERC-7540 REDEEM cycle state (by controller) ---
    mapping(address controller => uint256) public pendingRedeem;
    mapping(address controller => uint256) public claimableRedeemShares;
    mapping(address controller => uint256) public claimableRedeemAssets;

    /// @notice `isOperator[controller][operator]` — ERC-7540 operator delegation model.
    mapping(address controller => mapping(address operator => bool)) public isOperator;

    /// @dev Sum of `pendingDeposit` across all controllers. Assets counted here are still
    ///      the depositor's, not the pool's — excluded from {totalAssets}.
    uint256 public totalPendingDepositAssets;

    /// @dev Sum of `claimableRedeemAssets` across all controllers. Assets counted here have
    ///      already left the pool from an accounting standpoint (shares already burned in
    ///      {fulfillRedeem}) even though the ERC-20 balance hasn't moved — excluded from
    ///      {totalAssets}. See contract NatSpec point 3.
    uint256 public totalClaimableRedeemAssets;

    /// @dev Reserved storage gap so a future `RwaVaultV2` (ARCHITECTURE.md §3.4) can append
    ///      new state (e.g. a management-fee bps + recipient) without shifting these slots.
    uint256[50] private __gap;

    // ------------------------------------------------------------------
    // Events
    // ------------------------------------------------------------------

    event DepositRequest(
        address indexed controller, address indexed owner, uint256 indexed requestId, address sender, uint256 assets
    );
    event RedeemRequest(
        address indexed controller, address indexed owner, uint256 indexed requestId, address sender, uint256 shares
    );
    event OperatorSet(address indexed controller, address indexed operator, bool approved);
    event DepositFulfilled(address indexed controller, uint256 assets, uint256 shares);
    event RedeemFulfilled(address indexed controller, uint256 shares, uint256 assets);

    /// @notice `ASSET_MANAGER_ROLE` pulled `amount` of the asset out to fund an off-chain
    ///         T-bill purchase (see contract NatSpec point 4).
    event AssetInvested(address indexed assetManager, uint256 amount);

    /// @notice `ASSET_MANAGER_ROLE` returned `amount` of the asset from an off-chain T-bill sale.
    event AssetDivested(address indexed assetManager, uint256 amount);

    // ------------------------------------------------------------------
    // Errors
    // ------------------------------------------------------------------

    error ZeroAddress();
    error ZeroAmount();
    error NotAuthorized();
    error ExceedsPending();
    error ExceedsClaimable();
    error PreviewDisabled();

    /// @notice The NAV feed's last update is older than {MAX_STALENESS}.
    error StaleNav(uint256 updatedAt, uint256 currentTimestamp);

    /// @notice The NAV feed returned a non-positive answer.
    error InvalidNavAnswer(int256 answer);

    /// @notice `investInTBill` requested more than {_freeAssetBuffer} has available.
    error InsufficientFreeBuffer(uint256 requested, uint256 available);

    /// @notice `fulfillRedeem` would commit more assets than the vault holds liquid.
    /// @dev Hallazgo (c) de la campaña de invariantes del D3: sin este cap, el operador
    /// podía fijar un claim valuado por NAV contra holdings ilíquidos de tBILL — una
    /// promesa sin respaldo cuyo `claim` posterior revertía en la cara del usuario.
    /// La regla operativa real de los vaults RWA ("divest primero, fulfill después")
    /// se fuerza acá on-chain en vez de confiarse a un runbook.
    error InsufficientLiquidity(uint256 requested, uint256 available);

    // ------------------------------------------------------------------
    // Construction / initialization
    // ------------------------------------------------------------------

    /// @dev Locks initializers on the implementation contract itself so it can never be
    ///      used directly (only through a proxy that calls {initialize}).
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes a freshly-deployed proxy.
    /// @dev Every address parameter is zero-checked — an uninitialized proxy pointed at, say,
    ///      `navFeed == address(0)` would brick every NAV read forever with no recovery path
    ///      other than an upgrade, so this is validated up front rather than left to fail
    ///      later. Only `DEFAULT_ADMIN_ROLE` is granted here; see contract NatSpec point 2 for
    ///      why the four operational roles are deliberately left ungranted.
    /// @param asset_ The underlying deposit asset (a USDC-like ERC-20).
    /// @param tBillToken_ The synthetic T-bill token this vault will hold.
    /// @param navFeed_ The Chainlink-compatible NAV oracle for `tBillToken_`.
    /// @param admin_ Recipient of `DEFAULT_ADMIN_ROLE` (expected: a multisig).
    function initialize(IERC20 asset_, IERC20Metadata tBillToken_, AggregatorV3Interface navFeed_, address admin_)
        external
        initializer
    {
        if (address(asset_) == address(0)) revert ZeroAddress();
        if (address(tBillToken_) == address(0)) revert ZeroAddress();
        if (address(navFeed_) == address(0)) revert ZeroAddress();
        if (admin_ == address(0)) revert ZeroAddress();

        __ERC20_init("RWA Yield Vault Share", "rwaYLD");
        __ERC4626_init(asset_);
        __AccessControl_init();
        __Pausable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);

        tBillToken = tBillToken_;
        navFeed = navFeed_;
    }

    /// @dev Same inflation-attack mitigation as YieldVault/AsyncVault (pieza #2): virtual
    ///      shares/assets via a decimals offset, independent of `tBillToken`'s own decimals.
    function _decimalsOffset() internal pure override returns (uint8) {
        return 6;
    }

    // ------------------------------------------------------------------
    // NAV accounting
    // ------------------------------------------------------------------

    /// @notice Total value backing outstanding shares: the vault's tBILL holdings priced at
    ///         the current NAV, plus whatever "free" asset buffer isn't already spoken for.
    /// @dev NAV accrual is the entire yield mechanism (ARCHITECTURE.md §3.3): nobody
    ///      transfers assets in, the NAV feed rising makes this number rise, which raises
    ///      price-per-share for every holder simultaneously. See {_freeAssetBuffer} for why
    ///      pending deposits and already-fulfilled redeem claims are excluded.
    function totalAssets() public view override returns (uint256) {
        uint256 tBillBalance = tBillToken.balanceOf(address(this));
        return _tBillValueInAsset(tBillBalance) + _freeAssetBuffer();
    }

    /// @dev Asset balance actually available to back the pool: the vault's raw balance of
    ///      `asset()`, minus what's still owed to un-fulfilled depositors
    ///      (`totalPendingDepositAssets`, never was the pool's), minus what's already been
    ///      earmarked for a fulfilled-but-unclaimed redeem (`totalClaimableRedeemAssets`,
    ///      no longer the pool's — see contract NatSpec point 3). Saturates at zero instead
    ///      of underflowing so a view function never reverts on rounding dust.
    function _freeAssetBuffer() internal view returns (uint256) {
        uint256 assetBalance = IERC20(asset()).balanceOf(address(this));
        uint256 reserved = totalPendingDepositAssets + totalClaimableRedeemAssets;
        return assetBalance > reserved ? assetBalance - reserved : 0;
    }

    /// @dev Single call site for `navFeed.latestRoundData()` — every function that needs a
    ///      NAV price goes through this, so the staleness/validity guard in point 1 of the
    ///      §4 mitigation table is enforced everywhere, not just in one code path.
    function _latestNav() private view returns (uint256 nav, uint8 navDec) {
        (, int256 answer,, uint256 updatedAt,) = navFeed.latestRoundData();
        if (answer <= 0) revert InvalidNavAnswer(answer);
        if (block.timestamp > updatedAt + MAX_STALENESS) revert StaleNav(updatedAt, block.timestamp);
        nav = uint256(answer);
        navDec = navFeed.decimals();
    }

    /// @dev Converts `tBillAmount` (in `tBillToken`'s own decimals) into an equivalent amount
    ///      of `asset()` (in the asset's own decimals), at the current NAV (in `navFeed`'s
    ///      own decimals). Decimals are read dynamically rather than assumed, per
    ///      ARCHITECTURE.md §2's "no asumas, chequeá decimales" consumer discipline. Skips
    ///      the oracle call entirely for a zero balance so an idle, pre-investment vault (or
    ///      one whose NAV feed hasn't published its first round yet) never bricks
    ///      {totalAssets} / new deposits.
    function _tBillValueInAsset(uint256 tBillAmount) internal view returns (uint256) {
        if (tBillAmount == 0) return 0;

        (uint256 nav, uint8 navDec) = _latestNav();
        uint8 tBillDec = tBillToken.decimals();
        uint8 assetDec = IERC20Metadata(asset()).decimals();

        uint256 numeratorExp = assetDec;
        uint256 denominatorExp = uint256(tBillDec) + uint256(navDec);

        // Two chained `mulDiv` calls instead of a raw `*`/`**` so every multiplication of
        // oracle-influenced values goes through Math's overflow-checked 512-bit path.
        if (numeratorExp >= denominatorExp) {
            uint256 scale = 10 ** (numeratorExp - denominatorExp);
            return tBillAmount.mulDiv(nav, 1).mulDiv(scale, 1);
        } else {
            uint256 scale = 10 ** (denominatorExp - numeratorExp);
            return tBillAmount.mulDiv(nav, scale);
        }
    }

    // ------------------------------------------------------------------
    // Operator model (ERC-7540)
    // ------------------------------------------------------------------

    /// @notice Approves/revokes `operator` to act on behalf of `msg.sender` as controller
    ///         (request/claim on their behalf).
    function setOperator(address operator, bool approved) external returns (bool) {
        isOperator[msg.sender][operator] = approved;
        emit OperatorSet(msg.sender, operator, approved);
        return true;
    }

    // ------------------------------------------------------------------
    // 1) REQUEST — pausable (contract NatSpec point 6)
    // ------------------------------------------------------------------

    /// @notice Requests a deposit of `assets`. Funds leave `owner` immediately and sit
    ///         pending under `controller` until an operator fulfills the request.
    function requestDeposit(uint256 assets, address controller, address owner)
        external
        whenNotPaused
        nonReentrant
        returns (uint256 requestId)
    {
        if (assets == 0) revert ZeroAmount();
        if (msg.sender != owner && !isOperator[owner][msg.sender]) revert NotAuthorized();

        IERC20(asset()).safeTransferFrom(owner, address(this), assets);
        pendingDeposit[controller] += assets;
        totalPendingDepositAssets += assets;

        emit DepositRequest(controller, owner, REQUEST_ID, msg.sender, assets);
        return REQUEST_ID;
    }

    /// @notice Requests a redemption of `shares`. Shares move into vault custody immediately
    ///         and sit pending under `controller` until an operator fulfills the request.
    function requestRedeem(uint256 shares, address controller, address owner)
        external
        whenNotPaused
        nonReentrant
        returns (uint256 requestId)
    {
        if (shares == 0) revert ZeroAmount();
        if (msg.sender != owner && !isOperator[owner][msg.sender]) revert NotAuthorized();

        _transfer(owner, address(this), shares);
        pendingRedeem[controller] += shares;

        emit RedeemRequest(controller, owner, REQUEST_ID, msg.sender, shares);
        return REQUEST_ID;
    }

    // ------------------------------------------------------------------
    // 2) FULFILL — OPERATOR_ROLE only, NEVER pausable (contract NatSpec point 6)
    // ------------------------------------------------------------------

    /// @notice Settles (all or part of) `controller`'s pending deposit at the NAV/share
    ///         price prevailing right now. Shares are fixed here, not at request time.
    /// @dev `convertToShares` floors — rounding always favors the vault (ARCHITECTURE.md §4).
    function fulfillDeposit(address controller, uint256 assets)
        external
        onlyRole(OPERATOR_ROLE)
        nonReentrant
        returns (uint256 shares)
    {
        if (assets == 0) revert ZeroAmount();
        if (assets > pendingDeposit[controller]) revert ExceedsPending();

        // `assets` is still excluded from totalAssets() via totalPendingDepositAssets at
        // this point, so convertToShares prices it fairly against the existing pool.
        shares = convertToShares(assets);

        pendingDeposit[controller] -= assets;
        totalPendingDepositAssets -= assets;
        _mint(address(this), shares); // custody until claimed

        claimableDepositAssets[controller] += assets;
        claimableDepositShares[controller] += shares;

        emit DepositFulfilled(controller, assets, shares);
    }

    /// @notice Settles (all or part of) `controller`'s pending redeem at the NAV/share price
    ///         prevailing right now: burns the custodied shares and earmarks the asset.
    /// @dev `convertToAssets` floors — rounding always favors the vault (ARCHITECTURE.md §4).
    function fulfillRedeem(address controller, uint256 shares)
        external
        onlyRole(OPERATOR_ROLE)
        nonReentrant
        returns (uint256 assets)
    {
        if (shares == 0) revert ZeroAmount();
        if (shares > pendingRedeem[controller]) revert ExceedsPending();

        assets = convertToAssets(shares);

        // Cap de liquidez (hallazgo (c), invariantes D3): solo se puede prometer lo que
        // hay líquido y no reservado. _freeAssetBuffer ya descuenta los depósitos
        // pendientes y los claims de redeem previos, así que este chequeo garantiza que
        // todo claimableRedeemAssets queda 100% respaldado por asset en el vault.
        uint256 available = _freeAssetBuffer();
        if (assets > available) revert InsufficientLiquidity(assets, available);

        pendingRedeem[controller] -= shares;
        _burn(address(this), shares);
        totalClaimableRedeemAssets += assets;

        claimableRedeemShares[controller] += shares;
        claimableRedeemAssets[controller] += assets;

        emit RedeemFulfilled(controller, shares, assets);
    }

    // ------------------------------------------------------------------
    // 3) CLAIM — deposit/mint/redeem/withdraw stop moving NEW funds and instead deliver
    //    what fulfillDeposit/fulfillRedeem already settled. NEVER pausable (point 6).
    // ------------------------------------------------------------------

    function deposit(uint256 assets, address receiver) public override returns (uint256) {
        return deposit(assets, receiver, msg.sender);
    }

    /// @notice Claims shares for up to `assets` of `controller`'s already-fulfilled deposit.
    /// @dev Partial claim rounds shares DOWN (floor) — the claimer gets no more than their
    ///      exact proportional share, any dust favors the vault.
    function deposit(uint256 assets, address receiver, address controller) public nonReentrant returns (uint256 shares) {
        if (msg.sender != controller && !isOperator[controller][msg.sender]) revert NotAuthorized();
        if (assets == 0) revert ZeroAmount();
        uint256 cAssets = claimableDepositAssets[controller];
        if (assets > cAssets) revert ExceedsClaimable();

        uint256 cShares = claimableDepositShares[controller];
        shares = assets == cAssets ? cShares : assets.mulDiv(cShares, cAssets);

        claimableDepositAssets[controller] = cAssets - assets;
        claimableDepositShares[controller] = cShares - shares;

        _transfer(address(this), receiver, shares);
        emit Deposit(controller, receiver, assets, shares);
    }

    function mint(uint256 shares, address receiver) public override returns (uint256) {
        return mint(shares, receiver, msg.sender);
    }

    /// @notice Claims exactly `shares` from `controller`'s already-fulfilled deposit.
    /// @dev Partial claim rounds the assets consumed UP (ceil) — the claimer's remaining
    ///      claimable bucket depletes at least as fast as proportional, favoring the vault.
    function mint(uint256 shares, address receiver, address controller) public nonReentrant returns (uint256 assets) {
        if (msg.sender != controller && !isOperator[controller][msg.sender]) revert NotAuthorized();
        if (shares == 0) revert ZeroAmount();
        uint256 cShares = claimableDepositShares[controller];
        if (shares > cShares) revert ExceedsClaimable();

        uint256 cAssets = claimableDepositAssets[controller];
        assets = shares == cShares ? cAssets : shares.mulDiv(cAssets, cShares, Math.Rounding.Ceil);

        claimableDepositShares[controller] = cShares - shares;
        claimableDepositAssets[controller] = cAssets - assets;

        _transfer(address(this), receiver, shares);
        emit Deposit(controller, receiver, assets, shares);
    }

    /// @notice Claims assets by burning up to `shares` of `controller`'s already-fulfilled
    ///         redeem (3rd argument repurposed from ERC-4626's `owner` to the 7540 `controller`).
    /// @dev Partial claim rounds the assets paid out DOWN (floor), favoring the vault.
    function redeem(uint256 shares, address receiver, address controller) public override nonReentrant returns (uint256 assets) {
        if (msg.sender != controller && !isOperator[controller][msg.sender]) revert NotAuthorized();
        if (shares == 0) revert ZeroAmount();
        uint256 cShares = claimableRedeemShares[controller];
        if (shares > cShares) revert ExceedsClaimable();

        uint256 cAssets = claimableRedeemAssets[controller];
        assets = shares == cShares ? cAssets : shares.mulDiv(cAssets, cShares);

        claimableRedeemShares[controller] = cShares - shares;
        claimableRedeemAssets[controller] = cAssets - assets;
        totalClaimableRedeemAssets -= assets;

        IERC20(asset()).safeTransfer(receiver, assets);
        emit Withdraw(msg.sender, receiver, controller, assets, shares);
    }

    /// @notice Claims exactly `assets` from `controller`'s already-fulfilled redeem (3rd
    ///         argument repurposed from ERC-4626's `owner` to the 7540 `controller`).
    /// @dev Partial claim rounds the shares consumed UP (ceil), favoring the vault.
    function withdraw(uint256 assets, address receiver, address controller) public override nonReentrant returns (uint256 shares) {
        if (msg.sender != controller && !isOperator[controller][msg.sender]) revert NotAuthorized();
        if (assets == 0) revert ZeroAmount();
        uint256 cAssets = claimableRedeemAssets[controller];
        if (assets > cAssets) revert ExceedsClaimable();

        uint256 cShares = claimableRedeemShares[controller];
        shares = assets == cAssets ? cShares : assets.mulDiv(cShares, cAssets, Math.Rounding.Ceil);

        claimableRedeemAssets[controller] = cAssets - assets;
        claimableRedeemShares[controller] = cShares - shares;
        totalClaimableRedeemAssets -= assets;

        IERC20(asset()).safeTransfer(receiver, assets);
        emit Withdraw(msg.sender, receiver, controller, assets, shares);
    }

    // ------------------------------------------------------------------
    // ERC-7540 pending/claimable views
    // ------------------------------------------------------------------

    function pendingDepositRequest(uint256, address controller) external view returns (uint256) {
        return pendingDeposit[controller];
    }

    function claimableDepositRequest(uint256, address controller) external view returns (uint256) {
        return claimableDepositAssets[controller];
    }

    function pendingRedeemRequest(uint256, address controller) external view returns (uint256) {
        return pendingRedeem[controller];
    }

    function claimableRedeemRequest(uint256, address controller) external view returns (uint256) {
        return claimableRedeemShares[controller];
    }

    // max*: in an async vault the max you can "deposit/mint/withdraw/redeem" (=claim) is
    // whatever is already claimable for that controller.
    function maxDeposit(address controller) public view override returns (uint256) {
        return claimableDepositAssets[controller];
    }

    function maxMint(address controller) public view override returns (uint256) {
        return claimableDepositShares[controller];
    }

    function maxRedeem(address controller) public view override returns (uint256) {
        return claimableRedeemShares[controller];
    }

    function maxWithdraw(address controller) public view override returns (uint256) {
        return claimableRedeemAssets[controller];
    }

    // The settlement price is fixed at fulfill time; previewing it makes no sense and ERC-7540
    // requires these to revert.
    function previewDeposit(uint256) public pure override returns (uint256) {
        revert PreviewDisabled();
    }

    function previewMint(uint256) public pure override returns (uint256) {
        revert PreviewDisabled();
    }

    function previewWithdraw(uint256) public pure override returns (uint256) {
        revert PreviewDisabled();
    }

    function previewRedeem(uint256) public pure override returns (uint256) {
        revert PreviewDisabled();
    }

    // ------------------------------------------------------------------
    // Treasury rails — ASSET_MANAGER_ROLE only, NEVER pausable (see contract NatSpec point 4
    // and point 6)
    // ------------------------------------------------------------------

    /// @notice Pulls `assetAmount` of the underlying asset out to the caller to fund an
    ///         off-chain T-bill purchase. Capped by {_freeAssetBuffer}: can never touch money
    ///         still owed to a pending depositor or already earmarked for a redeem claim.
    /// @dev Does NOT call `TBillToken.mint` — see contract NatSpec point 4 for why that stays
    ///      entirely outside this contract's authority.
    function investInTBill(uint256 assetAmount) external onlyRole(ASSET_MANAGER_ROLE) nonReentrant {
        if (assetAmount == 0) revert ZeroAmount();
        uint256 available = _freeAssetBuffer();
        if (assetAmount > available) revert InsufficientFreeBuffer(assetAmount, available);

        IERC20(asset()).safeTransfer(msg.sender, assetAmount);
        emit AssetInvested(msg.sender, assetAmount);
    }

    /// @notice Returns `assetAmount` of the underlying asset from the caller, representing
    ///         proceeds of an off-chain T-bill sale.
    function divestFromTBill(uint256 assetAmount) external onlyRole(ASSET_MANAGER_ROLE) nonReentrant {
        if (assetAmount == 0) revert ZeroAmount();

        IERC20(asset()).safeTransferFrom(msg.sender, address(this), assetAmount);
        emit AssetDivested(msg.sender, assetAmount);
    }

    // ------------------------------------------------------------------
    // Pause — PAUSER_ROLE only
    // ------------------------------------------------------------------

    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    // ------------------------------------------------------------------
    // UUPS upgradeability — UPGRADER_ROLE only
    // ------------------------------------------------------------------

    /// @dev The only gate on `upgradeToAndCall`. No other check, no timelock at this layer —
    ///      whatever governance process grants `UPGRADER_ROLE` is where that safety lives.
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {}

    // ------------------------------------------------------------------
    // ERC-165
    // ------------------------------------------------------------------

    /// @inheritdoc AccessControlUpgradeable
    function supportsInterface(bytes4 interfaceId) public view override(AccessControlUpgradeable) returns (bool) {
        return
            interfaceId == 0xe3bc4e65 || // operator methods (ERC-7540)
            interfaceId == 0xce3bbe50 || // async deposit
            interfaceId == 0x620ee8e4 || // async redeem
            super.supportsInterface(interfaceId);
    }
}
