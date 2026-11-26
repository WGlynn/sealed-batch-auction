# Sealed-Bid Batch Auction: reference implementation

Reference implementation and tests for a draft ERC (not yet filed): commit-reveal batch auctions that settle
every filled order at one uniform clearing price.

- `src/IERCSealedBatchAuction.sol`: the interface.
- `src/SealedBatchAuction.sol`: one token pair per venue, written for clarity, not gas (settlement is O(n^2);
  about 1.57M gas at the 32-order cap in `test_gasAtCap`). Not audited.
- `test/SealedBatchAuction.t.sol`: unit tests and a fuzz test of the settlement properties (conservation,
  uniform price, limits, volume maximality against an independent model, bounded rounding dust).

Run the tests with Foundry, scoped to the test file: `--match-path test/SealedBatchAuction.t.sol -vv`. CC0.
