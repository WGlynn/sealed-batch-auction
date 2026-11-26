# sealed-batch-auction

Reference implementation for a draft ERC, Sealed-Bid Batch Auction. Traders commit order hashes, the orders are
revealed together, and anyone can settle the batch, which clears each token pair at one price.

The draft is not filed yet.

- `src/IERCSealedBatchAuction.sol` is the interface.
- `src/SealedBatchAuction.sol` handles one token pair per venue. Settlement is O(n^2) in the orders of a batch,
  about 6.7M gas at the 64-order cap. Not audited.
- `test/SealedBatchAuction.t.sol` has 33 tests, including fuzz tests of token and deposit conservation, the
  clearing price against an independent model, limits, and rounding.

Known open problem: reveals are public as they land, so the last one to reveal can move the clearing price within
the spread.

Tests: `forge test --match-path test/SealedBatchAuction.t.sol`

Built with AI. Will Glynn set the direction and made the calls; Jarvis, a research agent built on Claude Opus 5.5
(Anthropic) running in Claude Code, did most of the prior-art search, the spec text, this implementation and its
tests, and two rounds of adversarial review by separate Claude Opus 5.5 agents. Will reviewed and approved it.

CC0.
