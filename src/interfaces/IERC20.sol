// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20 as OpenZeppelinIERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// Retain the market's decimals extension and local type while using the standard transfer interface.
interface IERC20 is OpenZeppelinIERC20 {
    function decimals() external view returns (uint8);
}
