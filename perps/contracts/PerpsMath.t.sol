// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {PerpsMathHarness} from "./mocks/PerpsMathHarness.sol";

contract PerpsMathTest is Test {
    PerpsMathHarness internal harness;
    uint256 internal constant P = 1e18;

    function setUp() public {
        harness = new PerpsMathHarness();
    }

    function test_EquityLong() public view {
        // margin 100, long 1, mark 110 → equity 210
        int256 eq = harness.equity(100 * int256(P), 1 * int256(P), 110 * P);
        assertEq(eq, 210 * int256(P));
    }

    function test_ApplyTradeTakerBuys() public view {
        (int256 tm, int256 tp, int256 mm, int256 mp) =
            harness.applyTrade(1000 * int256(P), 0, 1000 * int256(P), 0, 1 * P, 100 * P, true);
        // taker: pos +1, margin -100; maker: pos -1, margin +100
        assertEq(tp, 1 * int256(P));
        assertEq(tm, 900 * int256(P));
        assertEq(mp, -1 * int256(P));
        assertEq(mm, 1100 * int256(P));
    }

    function test_FillMarginProportional() public view {
        assertEq(harness.fillMargin(100 * P, 10 * P, 4 * P), 40 * P);
    }

    function test_CollateralizedLong() public view {
        // margin -50, long 1, mark 100, min 110% → still OK (ratio 2.0)
        assertTrue(harness.isCollateralized(-50 * int256(P), 1 * int256(P), 100 * P, 11 * P / 10));
        // mark 50 → not collateralized
        assertFalse(harness.isCollateralized(-50 * int256(P), 1 * int256(P), 50 * P, 11 * P / 10));
    }
}
