// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {PoolFixture} from "./helpers/PoolFixture.sol";
import {Test} from "forge-std/Test.sol";
import {PlaceRouter} from "../src/PlaceRouter.sol";
import {Canvas} from "../src/Canvas.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract PlaceHandler is Test {
    PlaceRouter internal router;
    Canvas internal canvas;
    address[2] internal users;
    uint160 internal buyLimit;
    uint160 internal sellLimit;

    constructor(PlaceRouter r, Canvas c, address a, address b, uint160 buy_, uint160 sell_) {
        router = r;
        canvas = c;
        users = [a, b];
        buyLimit = buy_;
        sellLimit = sell_;
    }

    function trade(uint8 who, bool buy, uint96 raw) external {
        uint256 amount = uint256(raw) % (5 ether) + 0.05 ether;
        vm.prank(users[who % 2]);
        router.swap(buy, true, amount, 1, buy ? buyLimit : sellLimit, block.timestamp);
    }

    function paint(uint8 who, uint16 pixel, uint8 colour) external {
        uint16[] memory ids = new uint16[](1);
        ids[0] = pixel % 16;
        uint8[] memory cs = new uint8[](1);
        cs[0] = colour % 16;
        vm.prank(users[who % 2]);
        canvas.paint(ids, cs);
    }

    function claim(uint8 who) external {
        vm.prank(users[who % 2]);
        canvas.claim();
    }

    function treasury() external {
        canvas.claimTreasury();
    }
}

contract PlaceInvariantTest is PoolFixture {
    function setUp() public {
        _setup(false);
        vm.warp(block.timestamp + 30 minutes);
        PlaceHandler handler = new PlaceHandler(router, canvas, alice, bob, _limit(true), _limit(false));
        targetContract(address(handler));
    }

    function invariantClaimsNeverExceedArtistAllocation() public view {
        assertLe(canvas.totalPaid(), canvas.totalArtistFees());
        assertLe(
            canvas.totalPaid() + canvas.claimable(alice) + canvas.claimable(bob), canvas.totalArtistFees()
        );
    }

    function invariantExactFeeBacking() public view {
        assertEq(
            manager.balanceOf(address(hook), uint256(uint160(address(imd)))) + canvas.totalPaid()
                + canvas.totalTreasuryPaid(),
            canvas.totalFees()
        );
        assertEq(imd.balanceOf(address(router)), 0);
        assertEq(token.balanceOf(address(router)), 0);
        assertEq(imd.balanceOf(address(hook)), 0);
    }
}
