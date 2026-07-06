// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
// Same non-upgradeable `ReentrancyGuard` as `RwaVault` — see that contract's NatSpec point 1
// for why it is proxy-safe without an `__ReentrancyGuard_init` step.
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {ERC4626Upgradeable} from
    "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

import {AggregatorV3Interface} from "./interfaces/AggregatorV3Interface.sol";

/// @title RwaVaultV2 — RwaVault + management fee, the live D4 upgrade target (ARCHITECTURE.md §3.4)
/// @author RWA Yield Protocol
/// @notice Functionally IDENTICAL to `RwaVault` — same ERC-7540 request/fulfill/claim cycle,
///         same NAV accounting, same roles, same rounding/pause/staleness discipline — plus
///         ONE new, bounded feature: an annualized management fee (capped at {MAX_FEE_BPS}),
///         accrued as share dilution to {feeRecipient} on every `fulfillDeposit`/
///         `fulfillRedeem`, or on demand via {accrueFees}.
/// @dev STORAGE LAYOUT DECISION — read this before touching a single line below.
///
///      This contract is a **structural copy** of `RwaVault`, deliberately NOT
///      `contract RwaVaultV2 is RwaVault`. Inheritance was the "obvious" option and was
///      rejected for one concrete, non-negotiable reason: `RwaVault.__gap` is declared
///      `private`. Solidity lays out a base contract's state variables — its named fields
///      AND its `__gap` — at fixed slots that a subclass can only ever append AFTER, never
///      rewrite or shrink; a subclass cannot repurpose a `private` gap it did not itself
///      declare. Only editing `RwaVault.sol` could turn 3 of its `__gap`'s 50 slots into
///      named fields, and this task's ownership boundary forbids touching `RwaVault.sol`.
///      So `contract RwaVaultV2 is RwaVault` would have either (a) left all 50 gap slots
///      permanently dead — new fields bolted on after slot 60, safe but not "consuming the
///      gap" — or (b) been structurally *unable* to end up with a genuine `uint256[47]` gap
///      at all, which is what ARCHITECTURE.md §3.4 / the D4 acceptance bar asks for.
///
///      The structural copy sidesteps this entirely: slots 0–10 below are declared in the
///      exact same order, with the exact same types, as `RwaVault`'s slots 0–10 (verify
///      against the committed `storage-layout/RwaVault.v1.txt` / `RwaVault.v2.txt` diff).
///      Slots 11–13 are the 3 new fee fields — literally consuming 3 of the 50 slots
///      `RwaVault` reserved. Slot 14 opens a fresh `uint256[47]` gap (50 − 3), so a
///      hypothetical `RwaVaultV3` inherits the same kind of runway `RwaVault` originally
///      left, minus what V2 just spent. This is the real-world UUPS convention: "V2" is not
///      a Solidity subclass of "V1" — it is a new implementation contract with a
///      storage-compatible PREFIX, deployed behind the SAME proxy via `upgradeToAndCall`.
///      (OpenZeppelin's own upgradeable releases evolve the exact same way: each version is
///      a rewrite with a compatible prefix, not a subclass chain.)
///
///      One category of state needs NONE of this care: every OZ upgradeable parent below
///      (`ERC4626Upgradeable`/`ERC20Upgradeable`, `AccessControlUpgradeable`,
///      `PausableUpgradeable`, `Initializable`, `UUPSUpgradeable`) keeps its state in
///      ERC-7201 *namespaced* storage — a struct at a fixed `keccak256`-derived slot, not a
///      sequential one. Balances, allowances, granted roles, the pause flag, the
///      initialization version and the UUPS implementation slot are therefore safe by
///      construction, identically, regardless of inheritance topology, AS LONG AS the same
///      base contracts are used the same way — which they are here (same imports as
///      `RwaVault`, verbatim). That is WHY `forge inspect storage-layout` on `RwaVault` only
///      ever lists its 11 directly-declared variables plus `__gap`: the namespaced OZ state
///      is invisible to that report and needs no diffing. Only `RwaVault`'s own sequential
///      slots are this file's concern.
///
///      Every function body below (deposit/redeem cycle, NAV accounting, roles, pause,
///      upgrade authorization) is copied verbatim from `RwaVault` — same logic, same
///      rounding, same guards, same events/errors (preserving the ABI the dApp already
///      speaks) — so the upgrade changes exactly one thing: the fee. See `RwaVault.sol`'s
///      own NatSpec for the rationale behind each inherited mechanism; it is not repeated
///      in full here to keep this file's diff-reviewable surface centered on the fee
///      feature.
contract RwaVaultV2 is
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
    // Roles (identical identifiers to RwaVault — same keccak256 hashes, so roles granted
    // under V1 remain meaningful, unchanged, under V2; see contract NatSpec).
    // ------------------------------------------------------------------

    bytes32 public constant ASSET_MANAGER_ROLE = keccak256("ASSET_MANAGER_ROLE");
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    // ------------------------------------------------------------------
    // Constants
    // ------------------------------------------------------------------

    uint256 public constant REQUEST_ID = 0;
    uint256 public constant MAX_STALENESS = 24 hours;

    /// @notice Denominator for {managementFeeBps} (100% = 10_000 bps).
    uint256 public constant BPS_DENOMINATOR = 10_000;

    /// @notice Reference year length used to annualize the management fee. Linear
    ///         (non-compounding), matching a flat T-bill-style rate.
    uint256 public constant SECONDS_PER_YEAR = 365 days;

    /// @notice Hard cap on {managementFeeBps}, enforced at {initializeV2} — the only
    ///         setter this version exposes. 200 bps = 2% annualized, ceiling.
    uint256 public constant MAX_FEE_BPS = 200;

    // ------------------------------------------------------------------
    // Storage — slots 0-10 IDENTICAL in name/type/order to RwaVault's slots 0-10.
    // Slots 11-13 are new (this is the 3 slots consumed out of RwaVault's __gap).
    // Slot 14 opens the reduced uint256[47] gap. See contract NatSpec for why this
    // file does not `is RwaVault` and instead reproduces the prefix by hand.
    // ------------------------------------------------------------------

    /// @notice The synthetic T-bill token this vault holds as its yield-bearing RWA leg.
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

    uint256 public totalPendingDepositAssets;
    uint256 public totalClaimableRedeemAssets;

    // --- NEW in V2: management fee state (slots 11-13, consumed from RwaVault's __gap) ---

    /// @notice Annualized management fee rate in basis points (1 bps = 0.01%), charged as
    ///         share dilution to {feeRecipient}. Set once at {initializeV2}, capped forever
    ///         at {MAX_FEE_BPS} — V2 exposes no separate setter.
    uint256 public managementFeeBps;

    /// @notice Recipient of the diluting fee shares minted by {_accrueFees}.
    address public feeRecipient;

    /// @notice Unix timestamp of the last fee accrual. Every accrual covers only the time
    ///         strictly after this timestamp, then resets it to `block.timestamp` — this is
    ///         what makes fee accrual non-compounding and never double-counted for the same
    ///         second (see {_accrueFees}).
    uint256 public lastFeeAccrual;

    /// @dev Reduced from RwaVault's `uint256[50]` — 3 slots consumed by the fields above.
    ///      A hypothetical RwaVaultV3 gets this same treatment: 47 slots to spend, minus
    ///      whatever it adds, leaving a fresh `uint256[N]` gap of its own.
    uint256[47] private __gap;

    // ------------------------------------------------------------------
    // Events (identical to RwaVault, preserving the ABI the dApp already speaks)
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
    event AssetInvested(address indexed assetManager, uint256 amount);
    event AssetDivested(address indexed assetManager, uint256 amount);

    /// @notice V2 upgrade initializer ran: the management fee is now live.
    event ManagementFeeInitialized(uint256 feeBps, address indexed feeRecipient);

    /// @notice A fee accrual minted `feeShares` (worth `feeAssets` at the time of minting)
    ///         to `recipient`, covering `elapsed` seconds since the previous accrual.
    event FeesAccrued(address indexed recipient, uint256 feeAssets, uint256 feeShares, uint256 elapsed);

    // ------------------------------------------------------------------
    // Errors (identical to RwaVault, plus one new for the fee cap)
    // ------------------------------------------------------------------

    error ZeroAddress();
    error ZeroAmount();
    error NotAuthorized();
    error ExceedsPending();
    error ExceedsClaimable();
    error PreviewDisabled();
    error StaleNav(uint256 updatedAt, uint256 currentTimestamp);
    error InvalidNavAnswer(int256 answer);
    error InsufficientFreeBuffer(uint256 requested, uint256 available);
    error InsufficientLiquidity(uint256 requested, uint256 available);

    /// @notice {initializeV2} was called with `feeBps` above {MAX_FEE_BPS}.
    error FeeTooHigh(uint256 requested, uint256 cap);

    // ------------------------------------------------------------------
    // Construction / initialization
    // ------------------------------------------------------------------

    /// @dev Locks initializers on the implementation contract itself. Identical rationale
    ///      to `RwaVault`'s constructor.
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes a freshly-deployed proxy directly on V2 (a NEW deployment that
    ///         skips V1 entirely — e.g. a future testnet redeploy). Byte-identical to
    ///         `RwaVault.initialize`; upgraded proxies coming FROM a live V1 never call this
    ///         again (their storage is already populated) — they only ever call
    ///         {initializeV2}.
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

    /// @notice One-time V2 upgrade initializer (ARCHITECTURE.md §3.4). Normal flow: an
    ///         already-initialized V1 proxy (`_initialized == 1`) calls `upgradeToAndCall`
    ///         with this function's calldata as the second argument, so the upgrade and the
    ///         fee activation happen atomically in one transaction.
    /// @dev `reinitializer(2)` reverts with `InvalidInitialization()` if `_initialized >= 2`
    ///      already — this is what makes the initializer non-re-executable (D4 acceptance:
    ///      "initializeV2 no re-ejecutable").
    /// @param feeBps Initial {managementFeeBps}. Capped at {MAX_FEE_BPS}; 0 is a valid
    ///        starting value (fee begins disabled). V2 exposes no separate rate setter —
    ///        raising or lowering it later is scoped to a future version's own initializer.
    /// @param feeRecipient_ Initial {feeRecipient}. Zero-checked: an unset recipient would
    ///        silently mint fee shares to `address(0)` forever, burning them with no
    ///        recovery path.
    function initializeV2(uint256 feeBps, address feeRecipient_) external reinitializer(2) {
        if (feeBps > MAX_FEE_BPS) revert FeeTooHigh(feeBps, MAX_FEE_BPS);
        if (feeRecipient_ == address(0)) revert ZeroAddress();

        managementFeeBps = feeBps;
        feeRecipient = feeRecipient_;
        lastFeeAccrual = block.timestamp;

        emit ManagementFeeInitialized(feeBps, feeRecipient_);
    }

    function _decimalsOffset() internal pure override returns (uint8) {
        return 6;
    }

    // ------------------------------------------------------------------
    // Management fee (NEW in V2)
    // ------------------------------------------------------------------

    /// @notice Anyone may trigger a fee accrual on demand (keeper-friendly). The formula
    ///         below takes no caller-supplied input and only ever mints shares to the fixed
    ///         {feeRecipient}, so permissionless access adds no attack surface.
    function accrueFees() external nonReentrant {
        _accrueFees();
    }

    /// @dev Single call site for fee accrual: {fulfillDeposit}, {fulfillRedeem} and the
    ///      public {accrueFees} all funnel through here — mirroring `RwaVault._latestNav`'s
    ///      single-call-site discipline for its own single guarded resource.
    ///
    ///      FORMULA (linear, non-compounding — matches a flat annual T-bill-style rate):
    ///
    ///          feeAssets = totalAssets() * managementFeeBps * elapsed / (10_000 * 365 days)
    ///
    ///      i.e. `managementFeeBps` is charged per FULL YEAR elapsed, pro-rated linearly for
    ///      partial periods, where `elapsed = block.timestamp - lastFeeAccrual`.
    ///
    ///      Never double-counted, never backdated: `lastFeeAccrual` is stamped to
    ///      `block.timestamp` UNCONDITIONALLY, before any early return. Two calls in the
    ///      same second therefore always see `elapsed == 0` on the second call (feeAssets
    ///      forced to 0, no re-mint) — and a call an hour after the last one only ever
    ///      charges for that hour, never the full history since `initializeV2` again.
    ///
    ///      feeAssets is converted to shares via {convertToShares} (floors, same rounding
    ///      direction RwaVault uses everywhere else) and MINTED to `feeRecipient` — never
    ///      transferred from anywhere. That mint IS the dilution: nobody's balance
    ///      decreases, but `totalSupply` grows against an unchanged `totalAssets()`, so
    ///      every OTHER holder's redeemable value drops by exactly `feeRecipient`'s new
    ///      proportional claim. `feeAssets` is computed from `totalAssets()` BEFORE the
    ///      mint (the mint cannot affect its own input), and `managementFeeBps` can never
    ///      exceed {MAX_FEE_BPS} for the entire life of this contract (no setter besides
    ///      {initializeV2} exists) — so a single call can never charge more than the
    ///      annualized cap, no matter how long `elapsed` is left to grow.
    function _accrueFees() internal {
        uint256 elapsed = block.timestamp - lastFeeAccrual;
        lastFeeAccrual = block.timestamp;
        if (elapsed == 0 || managementFeeBps == 0) return;

        uint256 assets = totalAssets();
        if (assets == 0) return;

        // Single mulDiv (not chained) for maximum precision: `managementFeeBps * elapsed`
        // and `BPS_DENOMINATOR * SECONDS_PER_YEAR` are both far below 2^256 for any
        // realistic (or fuzzed, bounded) elapsed time, so the raw products here cannot
        // overflow; routing the final division through Math.mulDiv still keeps this
        // consistent with RwaVault's discipline of never doing a raw multiply against an
        // oracle/asset-scaled value without going through the checked path.
        uint256 feeAssets = assets.mulDiv(managementFeeBps * elapsed, BPS_DENOMINATOR * SECONDS_PER_YEAR);
        if (feeAssets == 0) return;

        uint256 feeShares = convertToShares(feeAssets);
        if (feeShares == 0) return;

        _mint(feeRecipient, feeShares);
        emit FeesAccrued(feeRecipient, feeAssets, feeShares, elapsed);
    }

    // ------------------------------------------------------------------
    // NAV accounting (verbatim from RwaVault)
    // ------------------------------------------------------------------

    function totalAssets() public view override returns (uint256) {
        uint256 tBillBalance = tBillToken.balanceOf(address(this));
        return _tBillValueInAsset(tBillBalance) + _freeAssetBuffer();
    }

    function _freeAssetBuffer() internal view returns (uint256) {
        uint256 assetBalance = IERC20(asset()).balanceOf(address(this));
        uint256 reserved = totalPendingDepositAssets + totalClaimableRedeemAssets;
        return assetBalance > reserved ? assetBalance - reserved : 0;
    }

    function _latestNav() private view returns (uint256 nav, uint8 navDec) {
        (, int256 answer,, uint256 updatedAt,) = navFeed.latestRoundData();
        if (answer <= 0) revert InvalidNavAnswer(answer);
        if (block.timestamp > updatedAt + MAX_STALENESS) revert StaleNav(updatedAt, block.timestamp);
        nav = uint256(answer);
        navDec = navFeed.decimals();
    }

    function _tBillValueInAsset(uint256 tBillAmount) internal view returns (uint256) {
        if (tBillAmount == 0) return 0;

        (uint256 nav, uint8 navDec) = _latestNav();
        uint8 tBillDec = tBillToken.decimals();
        uint8 assetDec = IERC20Metadata(asset()).decimals();

        uint256 numeratorExp = assetDec;
        uint256 denominatorExp = uint256(tBillDec) + uint256(navDec);

        if (numeratorExp >= denominatorExp) {
            uint256 scale = 10 ** (numeratorExp - denominatorExp);
            return tBillAmount.mulDiv(nav, 1).mulDiv(scale, 1);
        } else {
            uint256 scale = 10 ** (denominatorExp - numeratorExp);
            return tBillAmount.mulDiv(nav, scale);
        }
    }

    // ------------------------------------------------------------------
    // Operator model (ERC-7540) — verbatim from RwaVault
    // ------------------------------------------------------------------

    function setOperator(address operator, bool approved) external returns (bool) {
        isOperator[msg.sender][operator] = approved;
        emit OperatorSet(msg.sender, operator, approved);
        return true;
    }

    // ------------------------------------------------------------------
    // 1) REQUEST — pausable (verbatim from RwaVault)
    // ------------------------------------------------------------------

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
    // 2) FULFILL — OPERATOR_ROLE only, NEVER pausable. Fee accrual (NEW in V2) runs first,
    //    so the current fulfillment is priced AFTER the fee dilution, not before it.
    // ------------------------------------------------------------------

    function fulfillDeposit(address controller, uint256 assets)
        external
        onlyRole(OPERATOR_ROLE)
        nonReentrant
        returns (uint256 shares)
    {
        if (assets == 0) revert ZeroAmount();
        if (assets > pendingDeposit[controller]) revert ExceedsPending();

        _accrueFees();

        shares = convertToShares(assets);

        pendingDeposit[controller] -= assets;
        totalPendingDepositAssets -= assets;
        _mint(address(this), shares); // custody until claimed

        claimableDepositAssets[controller] += assets;
        claimableDepositShares[controller] += shares;

        emit DepositFulfilled(controller, assets, shares);
    }

    function fulfillRedeem(address controller, uint256 shares)
        external
        onlyRole(OPERATOR_ROLE)
        nonReentrant
        returns (uint256 assets)
    {
        if (shares == 0) revert ZeroAmount();
        if (shares > pendingRedeem[controller]) revert ExceedsPending();

        _accrueFees();

        assets = convertToAssets(shares);

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
    // 3) CLAIM (verbatim from RwaVault) — NEVER pausable.
    // ------------------------------------------------------------------

    function deposit(uint256 assets, address receiver) public override returns (uint256) {
        return deposit(assets, receiver, msg.sender);
    }

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
    // ERC-7540 pending/claimable views (verbatim from RwaVault)
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
    // Treasury rails — ASSET_MANAGER_ROLE only, NEVER pausable (verbatim from RwaVault)
    // ------------------------------------------------------------------

    function investInTBill(uint256 assetAmount) external onlyRole(ASSET_MANAGER_ROLE) nonReentrant {
        if (assetAmount == 0) revert ZeroAmount();
        uint256 available = _freeAssetBuffer();
        if (assetAmount > available) revert InsufficientFreeBuffer(assetAmount, available);

        IERC20(asset()).safeTransfer(msg.sender, assetAmount);
        emit AssetInvested(msg.sender, assetAmount);
    }

    function divestFromTBill(uint256 assetAmount) external onlyRole(ASSET_MANAGER_ROLE) nonReentrant {
        if (assetAmount == 0) revert ZeroAmount();

        IERC20(asset()).safeTransferFrom(msg.sender, address(this), assetAmount);
        emit AssetDivested(msg.sender, assetAmount);
    }

    // ------------------------------------------------------------------
    // Pause — PAUSER_ROLE only (verbatim from RwaVault)
    // ------------------------------------------------------------------

    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    // ------------------------------------------------------------------
    // UUPS upgradeability — UPGRADER_ROLE only (verbatim from RwaVault)
    // ------------------------------------------------------------------

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {}

    // ------------------------------------------------------------------
    // ERC-165 (verbatim from RwaVault)
    // ------------------------------------------------------------------

    function supportsInterface(bytes4 interfaceId) public view override(AccessControlUpgradeable) returns (bool) {
        return
            interfaceId == 0xe3bc4e65 || // operator methods (ERC-7540)
            interfaceId == 0xce3bbe50 || // async deposit
            interfaceId == 0x620ee8e4 || // async redeem
            super.supportsInterface(interfaceId);
    }
}
