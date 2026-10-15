# LendingMarket

Single-collateral money market. Suppliers deposit the base asset and earn interest, borrowers post collateral and draw the base asset against it, and positions that fall below their borrowing power can be liquidated.

## Running it

`forge-std` is vendored under `lib/`. Install the pinned OpenZeppelin dependency before building a fresh checkout; its local source directory is excluded from Git.

```bash
forge install --no-git OpenZeppelin/openzeppelin-contracts@rev=cab19933c33c2ad1d4c7a84864a3601dddfd16f3
forge build
forge test
forge test -vvv --match-test <name>     # a single test, with traces
```

Requires Foundry. If you do not have it: `curl -L https://foundry.paradigm.xyz | bash && foundryup`

## Pinned dependencies

OpenZeppelin Contracts **v5.7.0**, commit [`cab19933c33c2ad1d4c7a84864a3601dddfd16f3`](https://github.com/OpenZeppelin/openzeppelin-contracts/tree/cab19933c33c2ad1d4c7a84864a3601dddfd16f3), provides `SafeERC20`. The install command above pins that exact revision under the Git-ignored `lib/openzeppelin-contracts/` directory without creating a submodule. Imports use the explicit `@openzeppelin/contracts/` remapping in `foundry.toml`. Install dependencies before running build or test commands in CI as well.

## Layout

```
src/
  LendingMarket.sol                 the implementation, and the only file you need to change
  TransparentUpgradeableProxy.sol   the proxy the market is deployed behind
  interfaces/                       IERC20, IPriceOracle (Chainlink-style aggregator)
  mocks/                            test doubles for the base asset, collateral and oracle
script/
  Deploy.s.sol                      staging deployment, mirrors the production topology
test/
  LendingMarket.t.sol               the suite the market ships with today
```

## How it works

**Accounting.** Supplier and borrower balances are stored as *principal* and scaled by two global indices, `baseSupplyIndex` and `baseBorrowIndex`. `accrueInterest()` advances both to the current timestamp. Present value is `principal * index / 1e18`, so a balance grows without anyone touching per-account storage.

**Asset settlement.** Listed assets must be standard 18-decimal ERC20 contracts without transfer fees or rebasing. Every token movement uses OpenZeppelin `SafeERC20.safeTransfer` or `safeTransferFrom` directly. SafeERC20 accepts no return data or a canonical `true` first return word (including trailing ABI data), rejects false/invalid returns, and bubbles token reverts. Failed transfers revert the entire operation, including accounting changes and both liquidation legs. Accounting assumes the requested token amount moves; SafeERC20 does not verify balance changes. Verify asset behavior and decimal compatibility before listing. Transfer failures expose SafeERC20 errors or the token's revert reason.

**Scaling.** Everything is 1e18 fixed point unless stated otherwise. The oracle quotes the collateral in base-asset terms, also 1e18. So with WETH at 2,000 base, `getPrice()` returns `2000e18`.

**Oracle validity and freshness.** Pricing requires an oracle reporting exactly 18 decimals, a strictly positive answer, a nonzero round ID, and `answeredInRound >= roundId`. The update timestamp must be no later than the current block, nonzero, and at most the market's configured `maxPriceAge` old (the boundary is inclusive). Initialization requires an explicit positive maximum age; staging and tests use one hour. Choose each market's policy to match its feed heartbeat, and update the feed and age together with `setOracle(address,uint256)`. Other decimal scales are rejected rather than rescaled. Invalid or unavailable oracle data makes price-dependent health checks, borrowing, collateral withdrawal with debt, and liquidation revert; debt-free `isHealthy()` returns true without querying the oracle. These checks validate reported metadata, not the correctness of the feed's economic price.

**Oracle upgrade migration and ABI.** This version appends `uint256 public maxPriceAge` after all original storage fields, including `_initialized`, preserving the existing storage prefix. The initializer appends a ninth argument, `uint256 maxPriceAge_`, and oracle updates now use `setOracle(address newOracle, uint256 maxPriceAge_)`; callers must update their encoded calls. The old initializer and single-argument setter selectors are no longer supported, and `maxPriceAge()` is a new getter. Existing initialized proxies have zero in the new slot after an upgrade: `getPrice()` deliberately reverts until the admin calls `setOracle(currentOracle, maxAge)` with a positive age appropriate for the existing feed. Do not reinitialize an existing proxy. Plan this configuration call as part of the upgrade before resuming price-dependent operations. New deployments supply the age in initialization. Changing the feed or age does not independently verify feed accuracy or heartbeat suitability.

**Borrowing power.** `collateralBalance * price * collateralFactor`, all 1e18 scaled. A position is healthy while its borrowing power covers its debt. `isHealthy()` is the single source of truth for this, and it is checked on any path that increases risk.

**Liquidation.** Once a position is unhealthy, anyone may repay part of its debt and receive collateral in exchange, plus the liquidation incentive. The incentive is 1e18 scaled and always at or above par, so `1.10e18` means the liquidator receives 110% of what they repaid, valued in collateral.

**Deployment.** The market is an implementation behind a `TransparentUpgradeableProxy`. All market state lives in the proxy's storage, which is why any change you make has to be layout-compatible with what is already deployed. The admin owns upgrades and risk parameters. A separate pause guardian can pause and unpause the market without reaching for the admin key.

## Roles

| Role | Held by | Remit |
|---|---|---|
| `admin` | governance timelock | upgrades, risk parameters, oracle changes, pausing and unpausing |
| `pauseGuardian` | operations multisig | pausing and unpausing the market (`setPaused(bool)`) |

The guardian controls whether the market is paused and can both pause with `setPaused(true)` and resume with `setPaused(false)`. Oracle changes affect collateral valuations and remain restricted to the admin through `setOracle`. The admin can also pause and unpause.

## Listed markets

See `script/Deploy.s.sol` for the current staging configuration.
