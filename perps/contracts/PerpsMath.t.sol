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

    function test_UnrealizedPnlLong() public view {
        // long 2 @ 100, mark 110 → pnl = 2 * 10 = 20
        int256 pnl = harness.unrealizedPnl(2 * int256(P), 100 * P, 110 * P);
        assertEq(pnl, 20 * int256(P));
    }

    function test_ApplyFillOpenThenPartialClose() public view {
        (int256 size, uint256 entry, int256 pnl) = harness.applyFill(0, 0, 5 * int256(P), 100 * P);
        assertEq(size, 5 * int256(P));
        assertEq(entry, 100 * P);
        assertEq(pnl, 0);

        (size, entry, pnl) = harness.applyFill(size, entry, -2 * int256(P), 120 * P);
        assertEq(size, 3 * int256(P));
        assertEq(entry, 100 * P);
        // close 2 long: pnl = 2 * 20 = 40
        assertEq(pnl, 40 * int256(P));
    }

    function test_SystemEquityIncludesInventory() public view {
        // cash 1000, short 1 @ 100, mark 90 → upnl = (-1)*(90-100)= +10 → equity 1010
        int256 eq = harness.systemEquity(1000 * P, -1 * int256(P), 100 * P, 90 * P);
        assertEq(eq, 1010 * int256(P));
    }
}
