// Mappings for RwaVault (contracts/src/RwaVault.sol). Each handler is a thin,
// 1:1 translation of an event into its immutable entity — no aggregation, no
// cross-event state (see schema.graphql header for why a derived
// `VaultDailySnapshot` was left out of scope).
import {
  DepositRequest as DepositRequestEvent,
  RedeemRequest as RedeemRequestEvent,
  DepositFulfilled as DepositFulfilledEvent,
  RedeemFulfilled as RedeemFulfilledEvent,
} from "../generated/RwaVault/RwaVault";
import {
  DepositRequest,
  RedeemRequest,
  DepositFulfilled,
  RedeemFulfilled,
} from "../generated/schema";

// Entity ids are built inline (tx hash + log index) in each handler rather than
// via a shared helper: AssemblyScript does not support TypeScript union-typed
// parameters (`A | B | C | D`), so a single generic `eventId(event)` across the
// four distinct generated event classes fails to compile.

export function handleDepositRequest(event: DepositRequestEvent): void {
  let entity = new DepositRequest(event.transaction.hash.toHex() + "-" + event.logIndex.toString());
  entity.controller = event.params.controller;
  entity.owner = event.params.owner;
  entity.requestId = event.params.requestId;
  entity.sender = event.params.sender;
  entity.assets = event.params.assets;
  entity.blockNumber = event.block.number;
  entity.blockTimestamp = event.block.timestamp;
  entity.transactionHash = event.transaction.hash;
  entity.save();
}

export function handleRedeemRequest(event: RedeemRequestEvent): void {
  let entity = new RedeemRequest(event.transaction.hash.toHex() + "-" + event.logIndex.toString());
  entity.controller = event.params.controller;
  entity.owner = event.params.owner;
  entity.requestId = event.params.requestId;
  entity.sender = event.params.sender;
  entity.shares = event.params.shares;
  entity.blockNumber = event.block.number;
  entity.blockTimestamp = event.block.timestamp;
  entity.transactionHash = event.transaction.hash;
  entity.save();
}

export function handleDepositFulfilled(event: DepositFulfilledEvent): void {
  let entity = new DepositFulfilled(event.transaction.hash.toHex() + "-" + event.logIndex.toString());
  entity.controller = event.params.controller;
  entity.assets = event.params.assets;
  entity.shares = event.params.shares;
  entity.blockNumber = event.block.number;
  entity.blockTimestamp = event.block.timestamp;
  entity.transactionHash = event.transaction.hash;
  entity.save();
}

export function handleRedeemFulfilled(event: RedeemFulfilledEvent): void {
  let entity = new RedeemFulfilled(event.transaction.hash.toHex() + "-" + event.logIndex.toString());
  entity.controller = event.params.controller;
  entity.shares = event.params.shares;
  entity.assets = event.params.assets;
  entity.blockNumber = event.block.number;
  entity.blockTimestamp = event.block.timestamp;
  entity.transactionHash = event.transaction.hash;
  entity.save();
}
