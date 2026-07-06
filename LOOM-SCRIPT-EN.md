# Loom Script — RWA Yield Protocol (4-5 min, English)

English translation of `LOOM-GUION.md`, built to work two ways:

1. **Spoken** — read it out loud in your own voice, short sentences on purpose so
   pronunciation stays easy and you can redo a line without losing the take.
2. **Text-only** — if you never get to recording narration, turn every plain
   paragraph below into an on-screen caption/callout over the same screen actions.
   The `[SHOW: ...]` cues already tell you what's on screen at each point — that's
   enough structure for a voiceless walkthrough too.

Either way, the proof is in the links (Etherscan, the repo, the live dApp), so the
video doesn't have to carry the whole argument by itself.

**Before recording, have these tabs open (in this order):**
1. Etherscan at `0x48c78Ffe5A882069FC81Fb866510FAAE625109C4` (the proxy), "Contract" tab → "Read as Proxy" if Etherscan detects it, or straight to the events/txs tab.
2. `ARCHITECTURE.md` §3 (the contract diagram), in an editor or Markdown preview.
3. `contracts/test/invariants/RwaVault.invariants.t.sol`, scrolled to `test_RedeemLiquidityGap_FulfillBeyondLiquidBuffer_RevertsAfterFix`.
4. The dApp running locally (`npm run dev` in `dapp/`) or the deployed version if you published it, with MetaMask on Sepolia.
5. A terminal with `cast` ready, in case you want to run the command live instead of just showing it pasted.

---

## 0. Hook — the live upgrade (0:00–0:30)

[SHOW: Etherscan, the upgrade tx — `0xa42a4c94f41756ec0e84986c61160c0277e0538d57aeeb313642d7fef1844594`]

Hi. This is a DeFi protocol that tokenizes a T-bill and pays yield to whoever
deposits. But that's not what I want to show first.

I want to show this: this transaction changed the code behind this contract. Live.
On Sepolia. With real money inside — well, testnet money, but with real deposits
already made, from before the upgrade.

The contract address didn't change. The code behind it did. And everything that was
inside — the deposits, the roles, the balance — survived.

That's a UUPS upgrade actually executed, not a whiteboard demo. Let me show you how
it works.

---

## 1. Contract map (0:30–1:30)

[SHOW: `ARCHITECTURE.md` §3, the ASCII contract diagram]

Three pieces that talk to each other.

First, `TBillToken`. A plain ERC-20. Represents the synthetic T-bill. No exotic
logic on purpose — the value doesn't live in the token.

The value lives in `RwaNavFeed`. It's an oracle. It implements the SAME interface
as a Chainlink feed — `AggregatorV3Interface` — so the day a real T-bill feed
exists, it plugs in without touching a single line of the vault. Someone — an
authorized role — publishes the NAV. With two guardrails: it can't move more than
five percent per update, and it can't update more than once an hour. That turns a
typo or a stolen key into an incident you can stop, not an instant drain.

And the core: `RwaVault`. This is where it gets interesting. It's not a plain
ERC-4626 vault, where the share price comes from the contract's balance. Here the
price comes from the NAV. Nobody transfers yield into the vault — the NAV goes up,
and the share price goes up on its own. It's accounting, not a transfer.

And it's asynchronous: you deposit, someone with the operator role settles your
request at the current price, and then you claim. Three steps, not one. That's the
ERC-7540 standard, built exactly for assets that don't have instant liquidity — like
a T-bill.

---

## 2. Finding (c) — the story (1:30–3:00)

[SHOW: `test/invariants/RwaVault.invariants.t.sol`, the flipped test]

Now the part I most want to show, because it's the one that proves this was
actually audited, not just built and shipped.

During construction I ran an invariant testing campaign. What that means: instead
of writing "check that this happens, then that" — which is what a normal test
does — you give a fuzzer a set of valid protocol actions, and ask it to combine
them randomly, thousands of times, with several actors acting in parallel. After
every combination, it checks one property that must ALWAYS hold. Here the property
was simple: the vault must always have enough liquid cash to cover what it owes
people.

On the very first run, that property broke.

The fuzzer found a sequence — nobody wrote it by hand, it generated it on its own —
where the operator settled a redemption request, the contract calculated what it
owed that person using the NAV... and that calculation never checked whether real
cash was actually available. The value was there, but in T-bill, not in cash. The
contract promised something it couldn't pay out at that moment. And when the person
tried to claim, the transaction reverted. An unbacked promise, right in the user's
face.

This wasn't on the list of attack vectors I'd written before the audit. The machine
found it, by combining actions that were each normal on their own.

And that's where I had to decide: fix this with an operating procedure — "hey,
only settle redemptions after selling the T-bill" — or fix it in the contract?

I fixed it in the contract. Because here the victim is a user, not the protocol. A
procedure can be forgotten. A `require` can't.

[SHOW: `RwaVault.sol`, the `InsufficientLiquidity` error and the check in `fulfillRedeem`]

So now `fulfillRedeem` calculates how much liquid cash is actually available, and
if what it would owe that person exceeds that, it reverts right there, with an
explicit error. The rule that used to be "remember to do it in this order" is now a
rule the contract enforces on its own.

And the test that used to prove the bug was flipped on purpose: now it proves that
this exact scenario, the one that used to break the promise, reverts cleanly today.

To me, this is what a real audit looks like: not "we found nothing." It's "we found
something that wasn't even on the list, and we chose to fix it in the right place."

---

## 3. dApp demo (3:00–4:00)

[SHOW: the dApp, wallet connected on Sepolia]

This is the full flow, from the user's side.

[SHOW: deposit screen, requestDeposit]

I deposit test USDC. The request stays pending — I don't have shares yet.

[SHOW: admin panel or pending → claimable state]

The operator settles the request at the current NAV. That's when my deposit moves
from pending to claimable.

[SHOW: claim button, confirmed transaction]

I claim, and now I actually have vault shares in my wallet.

[SHOW: NAV panel / share value]

And here's the NAV panel: if the operator raises the T-bill's value, my shares are
worth more, without anyone transferring me anything. That's the protocol's entire
yield mechanism, visible on one screen.

---

## 4. Closing with numbers (4:00–4:30)

[SHOW: README.md, the address table, or Etherscan again]

To close, in numbers: 3 contracts, deployed and verified on Sepolia. One real UUPS
upgrade, with state preserved, verifiable with `cast` in five commands — they're all
in the README, ready to copy-paste. 148 tests: unit, fuzz, multi-actor invariants,
and a fork test against a real Chainlink feed. And 3 audit findings documented with
their full process, not just the result.

This is what I wanted to show: not a contract that compiles. A protocol that got
audited, got attacked on purpose, and survived a real upgrade with money inside.

Thanks for watching.
