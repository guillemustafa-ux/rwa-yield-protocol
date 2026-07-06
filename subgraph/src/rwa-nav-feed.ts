// Mapping for RwaNavFeed (contracts/src/RwaNavFeed.sol) — one handler for its
// single event, NavUpdated (RwaNavFeed.sol lines ~66-70, ~101-125).
import { NavUpdated as NavUpdatedEvent } from "../generated/RwaNavFeed/RwaNavFeed";
import { NavUpdate } from "../generated/schema";

export function handleNavUpdated(event: NavUpdatedEvent): void {
  let entity = new NavUpdate(event.transaction.hash.toHex() + "-" + event.logIndex.toString());
  entity.roundId = event.params.roundId;
  entity.nav = event.params.nav;
  entity.updatedAt = event.params.updatedAt;
  entity.blockNumber = event.block.number;
  entity.blockTimestamp = event.block.timestamp;
  entity.transactionHash = event.transaction.hash;
  entity.save();
}
