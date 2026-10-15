# LendingMarket

Single-collateral money market. Suppliers deposit the base asset and earn interest, borrowers post collateral and draw the base asset against it, and positions that fall below their borrowing power can be liquidated.

## Running it

The project is self-contained. `forge-std` and the OpenZeppelin dependency subset are vendored under `lib/`, so no network access or `forge install` is needed once Foundry and the pinned Solidity 0.8.24 compiler are available.

```bash
forge build
forge test
forge test -vvv --match-test <name>     # a single test, with traces
```

Requires Foundry. If you do not have it: `curl -L https://foundry.paradigm.xyz | bash && foundryup`

## Pinned dependencies

OpenZeppelin Contracts **v5.7.0**, commit [`cab19933c33c2ad1d4c7a84864a3601dddfd16f3`](https://github.com/OpenZeppelin/openzeppelin-contracts/tree/cab19933c33c2ad1d4c7a84864a3601dddfd16f3), is vendored unmodified under `lib/openzeppelin-contracts/`. The subset contains the complete import closure of `SafeERC20` and `Math` (for the accounting follow-up), plus the upstream MIT license, provenance, and SHA-256 checksums. Its `^0.8.20` pragmas are compatible with this project's Solidity 0.8.24. Imports use the explicit `@openzeppelin/contracts/` remapping in `foundry.toml`; no submodule or runtime install is required. See [dependency provenance](lib/openzeppelin-contracts/README.vendor.md).

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

**Asset settlement.** Supported market assets are 18-decimal, exact-transfer ERC20 contracts. Every token movement uses OpenZeppelin `SafeERC20.safeTransfer` or `safeTransferFrom` directly. SafeERC20 accepts no return data or a canonical `true` first return word (including trailing ABI data), rejects false/invalid returns, and bubbles token reverts. The market separately checks the exact amount received on incoming payments and both the exact reserve debit and recipient credit on outgoing payments. A failed call or mismatch reverts the entire operation, including interest accrual, principal, collateral, allowances, and both liquidation legs. Fee-on-transfer, rebasing, and otherwise inexact assets are unsupported; sender-paid fees on incoming payments are not checked when the market receives the full amount. Decimal compatibility and token trust must be verified before listing: these settlement checks do not make a malicious token's reported balances trustworthy. This change retains the existing storage and public function/event ABI; transfer failures now expose SafeERC20 errors or the token's revert reason instead of the previous generic error.

**Scaling.** Everything is 1e18 fixed point unless stated otherwise. The oracle quotes the collateral in base-asset terms, also 1e18. So with WETH at 2,000 base, `getPrice()` returns `2000e18`.

**Oracle validity and freshness.** Pricing requires an oracle reporting exactly 18 decimals, a strictly positive answer, a nonzero round ID, and `answeredInRound >= roundId`. The update timestamp must be no later than the current block, nonzero, and at most the market's configured `maxPriceAge` old (the boundary is inclusive). Initialization requires an explicit positive maximum age; staging and tests use one hour. Choose each market's policy to match its feed heartbeat, and update the feed and age together with `setOracle(address,uint256)`. Other decimal scales are rejected rather than rescaled. Invalid or unavailable oracle data makes price-dependent health checks, borrowing, collateral withdrawal with debt, and liquidation revert; debt-free `isHealthy()` returns true without querying the oracle. These checks validate reported metadata, not the correctness of the feed's economic price.

**Oracle upgrade migration and ABI.** This version appends `uint256 public maxPriceAge` after all original storage fields, including `_initialized`, preserving the existing storage prefix. The initializer appends a ninth argument, `uint256 maxPriceAge_`, and oracle updates now use `setOracle(address newOracle, uint256 maxPriceAge_)`; callers must update their encoded calls. The old initializer and single-argument setter selectors are no longer supported, and `maxPriceAge()` is a new getter. Existing initialized proxies have zero in the new slot after an upgrade: `getPrice()` deliberately reverts until the admin calls `setOracle(currentOracle, maxAge)` with a positive age appropriate for the existing feed. Do not reinitialize an existing proxy. Plan this configuration call as part of the upgrade before resuming price-dependent operations. New deployments supply the age in initialization. Changing the feed or age does not independently verify feed accuracy or heartbeat suitability.

**Borrowing power.** `collateralBalance * price * collateralFactor`, all 1e18 scaled. A position is healthy while its borrowing power covers its debt. `isHealthy()` is the single source of truth for this, and it is checked on any path that increases risk.

**Liquidation.** Once a position is unhealthy, anyone may repay part of its debt and receive collateral in exchange, plus the liquidation incentive. The incentive is 1e18 scaled and always at or above par, so `1.10e18` means the liquidator receives 110% of what they repaid, valued in collateral.

**Deployment.** The market is an implementation behind a `TransparentUpgradeableProxy`. All market state lives in the proxy's storage, which is why any change you make has to be layout-compatible with what is already deployed. The admin owns upgrades and risk parameters. A separate pause guardian exists so the market can be stopped quickly without reaching for the admin key.

## Roles

| Role | Held by | Remit |
|---|---|---|
| `admin` | governance timelock | upgrades, risk parameters, wiring |
| `pauseGuardian` | operations multisig | stopping the market in an incident |

The split matters. The guardian key is warmer and held by more people than the admin key, so anything the guardian can reach should be limited to stopping the market, not changing how it prices or values anything.

## Listed markets

See `script/Deploy.s.sol` for the current staging configuration.
