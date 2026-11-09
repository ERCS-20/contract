// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {SpotMiningPool} from "../contracts/SpotMiningPool.sol";
import {PerpsMiningPool} from "../contracts/PerpsMiningPool.sol";

contract MockStakeToken is ERC20 {
    constructor() ERC20("OBX", "OBX") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockSpotVault {
    mapping(address => uint256) public tokenFees;
    address public wusdc;
    address public pool;

    constructor(address wusdc_) {
        wusdc = wusdc_;
    }

    function setPool(address pool_) external {
        pool = pool_;
    }

    function addFees(address token, uint256 amount) external {
        tokenFees[token] += amount;
        if (token != wusdc) {
            ERC20(token).transferFrom(msg.sender, address(this), amount);
        }
    }

    function claimFees(address token, uint256 amount) external {
        require(msg.sender == pool, "not pool");
        tokenFees[token] -= amount;
        if (token == wusdc) {
            (bool ok,) = msg.sender.call{value: amount}("");
            require(ok, "native pay");
        } else {
            ERC20(token).transfer(msg.sender, amount);
        }
    }

    receive() external payable {}
}

contract MockPerpsVault {
    uint256 public protocolFees;
    address public pool;

    function setPool(address pool_) external {
        pool = pool_;
    }

    function addFees() external payable {
        protocolFees += msg.value;
    }

    function claimFees(uint256 amount) external {
        require(msg.sender == pool, "not pool");
        protocolFees -= amount;
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "native pay");
    }
}

contract MiningPoolTest is Test {
    MockStakeToken internal obx;
    MockStakeToken internal reward;
    MockSpotVault internal spotVault;
    SpotMiningPool internal spot;
    MockPerpsVault internal perpsVault;
    PerpsMiningPool internal perps;

    address internal operator = makeAddr("operator");
    address internal withdrawer = makeAddr("withdrawer");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        obx = new MockStakeToken();
        reward = new MockStakeToken();
        spotVault = new MockSpotVault(address(0));
        spot = new SpotMiningPool(address(obx), address(spotVault));
        spotVault.setPool(address(spot));
        spot.setOperator(operator);
        spot.setWithdrawer(withdrawer);

        perpsVault = new MockPerpsVault();
        perps = new PerpsMiningPool(address(obx), address(perpsVault));
        perpsVault.setPool(address(perps));
        perps.setWithdrawer(withdrawer);

        obx.mint(alice, 1_000 ether);
        obx.mint(bob, 1_000 ether);
        vm.prank(alice);
        obx.approve(address(spot), type(uint256).max);
        vm.prank(alice);
        obx.approve(address(perps), type(uint256).max);
        vm.prank(bob);
        obx.approve(address(spot), type(uint256).max);
    }

    function test_stakeUnstakeAndProportionalUserHalf() public {
        vm.prank(operator);
        spot.setMiningEnabled(address(reward), true);

        vm.prank(alice);
        spot.stake(address(reward), 100 ether);
        vm.prank(bob);
        spot.stake(address(reward), 300 ether);

        reward.mint(address(this), 800 ether);
        reward.approve(address(spotVault), 800 ether);
        spotVault.addFees(address(reward), 800 ether);

        assertEq(spot.rewardBalance(address(reward)), 800 ether);
        assertEq(spot.earned(alice, address(reward)), 100 ether);
        assertEq(spot.earned(bob, address(reward)), 300 ether);
        assertEq(reward.balanceOf(address(spot)), 0);

        vm.prank(alice);
        spot.claim(address(reward));

        assertEq(reward.balanceOf(alice), 100 ether);
        assertEq(reward.balanceOf(address(spot)), 100 ether);
        assertEq(spot.systemReserve(address(reward)), 100 ether);
        assertEq(spotVault.tokenFees(address(reward)), 600 ether);
        assertEq(spot.earned(bob, address(reward)), 300 ether);
    }

    function test_disabledMiningStillPaysBookedRewards() public {
        vm.prank(operator);
        spot.setMiningEnabled(address(reward), true);
        vm.prank(alice);
        spot.stake(address(reward), 100 ether);

        reward.mint(address(this), 400 ether);
        reward.approve(address(spotVault), 400 ether);
        spotVault.addFees(address(reward), 200 ether);
        assertEq(spot.earned(alice, address(reward)), 100 ether);

        vm.prank(operator);
        spot.setMiningEnabled(address(reward), false);
        spotVault.addFees(address(reward), 200 ether);

        assertEq(spot.rewardBalance(address(reward)), 0);
        assertEq(spot.earned(alice, address(reward)), 100 ether);

        vm.prank(alice);
        spot.claim(address(reward));
        assertEq(reward.balanceOf(alice), 100 ether);

        vm.prank(operator);
        spot.setMiningEnabled(address(reward), true);
        assertEq(spot.rewardBalance(address(reward)), 200 ether);
        assertEq(spot.earned(alice, address(reward)), 100 ether);
    }

    function test_feesWaitForTheFirstStaker() public {
        vm.prank(operator);
        spot.setMiningEnabled(address(reward), true);
        reward.mint(address(this), 200 ether);
        reward.approve(address(spotVault), 200 ether);
        spotVault.addFees(address(reward), 200 ether);

        assertEq(spot.earned(alice, address(reward)), 0);
        vm.prank(alice);
        spot.stake(address(reward), 100 ether);
        assertEq(reward.balanceOf(alice), 0);
        assertEq(spot.earned(alice, address(reward)), 100 ether);

        vm.prank(alice);
        spot.claim(address(reward));
        assertEq(reward.balanceOf(alice), 100 ether);
        assertEq(spot.earned(alice, address(reward)), 0);
        assertEq(spot.systemReserve(address(reward)), 100 ether);
    }

    function test_canStakeWhileMiningIsOff() public {
        vm.prank(alice);
        spot.stake(address(reward), 50 ether);
        assertEq(spot.stakedOf(alice, address(reward)), 50 ether);
        assertEq(spot.rewardBalance(address(reward)), 0);

        vm.prank(alice);
        spot.unstake(address(reward), 50 ether);
        assertEq(obx.balanceOf(alice), 1_000 ether);
    }

    function test_rescueMistakenTokenButNotStakeOrSystemHalf() public {
        MockStakeToken stray = new MockStakeToken();
        stray.mint(address(spot), 7 ether);
        stray.mint(address(perps), 4 ether);

        vm.prank(alice);
        vm.expectRevert(SpotMiningPool.NotWithdrawer.selector);
        spot.rescue(address(stray), withdrawer, 7 ether);

        vm.prank(withdrawer);
        vm.expectRevert(SpotMiningPool.StakeToken.selector);
        spot.rescue(address(obx), withdrawer, 1 ether);

        vm.prank(withdrawer);
        spot.rescue(address(stray), withdrawer, 7 ether);
        assertEq(stray.balanceOf(withdrawer), 7 ether);

        vm.prank(operator);
        spot.setMiningEnabled(address(reward), true);
        vm.prank(alice);
        spot.stake(address(reward), 100 ether);
        reward.mint(address(this), 200 ether);
        reward.approve(address(spotVault), 200 ether);
        spotVault.addFees(address(reward), 200 ether);
        vm.prank(alice);
        spot.claim(address(reward));
        reward.mint(address(spot), 5 ether);

        vm.prank(withdrawer);
        spot.rescue(address(reward), withdrawer, 5 ether);
        assertEq(spot.systemReserve(address(reward)), 100 ether);
        assertEq(reward.balanceOf(address(spot)), 100 ether);

        vm.prank(withdrawer);
        perps.rescue(address(stray), withdrawer, 4 ether);
        assertEq(stray.balanceOf(withdrawer), 11 ether);
    }

    function test_onlyWithdrawerTakesSystemHalf() public {
        vm.prank(operator);
        spot.setMiningEnabled(address(reward), true);
        vm.prank(alice);
        spot.stake(address(reward), 100 ether);
        reward.mint(address(this), 200 ether);
        reward.approve(address(spotVault), 200 ether);
        spotVault.addFees(address(reward), 200 ether);
        vm.prank(alice);
        spot.claim(address(reward));

        vm.prank(alice);
        vm.expectRevert(SpotMiningPool.NotWithdrawer.selector);
        spot.withdrawSystem(address(reward), 100 ether);

        vm.prank(withdrawer);
        spot.withdrawSystem(address(reward), 40 ether);
        assertEq(reward.balanceOf(withdrawer), 40 ether);
        assertEq(spot.systemReserve(address(reward)), 60 ether);
    }

    function test_wusdcClaimPaysNativeUsdc() public {
        MockStakeToken wrapped = new MockStakeToken();
        MockSpotVault nativeVault = new MockSpotVault(address(wrapped));
        SpotMiningPool nativePool = new SpotMiningPool(address(obx), address(nativeVault));
        nativeVault.setPool(address(nativePool));
        nativePool.setOperator(operator);
        nativePool.setWithdrawer(withdrawer);

        vm.prank(alice);
        obx.approve(address(nativePool), type(uint256).max);
        vm.prank(operator);
        nativePool.setMiningEnabled(address(wrapped), true);
        vm.prank(alice);
        nativePool.stake(address(wrapped), 100 ether);

        vm.deal(address(nativeVault), 200 ether);
        nativeVault.addFees(address(wrapped), 200 ether);

        uint256 before = alice.balance;
        vm.prank(alice);
        nativePool.claim(address(wrapped));
        assertEq(alice.balance - before, 100 ether);
        assertEq(address(nativePool).balance, 100 ether);
        assertEq(nativePool.systemNative(), 100 ether);

        vm.prank(withdrawer);
        nativePool.withdrawSystem(address(wrapped), 100 ether);
        assertEq(withdrawer.balance, 100 ether);
        assertEq(nativePool.systemNative(), 0);
    }

    function test_perpsClaimKeepsSystemHalfUntilWithdrawn() public {
        vm.prank(alice);
        perps.stake(100 ether);
        vm.deal(address(this), 200 ether);
        perpsVault.addFees{value: 200 ether}();

        assertEq(perps.rewardBalance(), 200 ether);
        assertEq(perps.earned(alice), 100 ether);
        assertEq(address(perps).balance, 0);

        uint256 before = alice.balance;
        vm.prank(alice);
        perps.claim();
        assertEq(alice.balance - before, 100 ether);
        assertEq(perps.systemNative(), 100 ether);
        assertEq(address(perps).balance, 100 ether);

        vm.prank(withdrawer);
        perps.withdrawSystem(100 ether);
        assertEq(withdrawer.balance, 100 ether);
        assertEq(address(perps).balance, 0);
    }

    function test_unstakePaysRewards() public {
        vm.prank(operator);
        spot.setMiningEnabled(address(reward), true);
        vm.prank(alice);
        spot.stake(address(reward), 100 ether);
        reward.mint(address(this), 200 ether);
        reward.approve(address(spotVault), 200 ether);
        spotVault.addFees(address(reward), 200 ether);

        vm.prank(alice);
        spot.unstake(address(reward), 100 ether);
        assertEq(spot.stakedOf(alice, address(reward)), 0);
        assertEq(spot.earned(alice, address(reward)), 0);
        assertEq(reward.balanceOf(alice), 100 ether);
        assertEq(spot.systemReserve(address(reward)), 100 ether);
    }
}
