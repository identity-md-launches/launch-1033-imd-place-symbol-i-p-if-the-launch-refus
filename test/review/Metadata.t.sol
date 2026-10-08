// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Canvas} from "../../src/Canvas.sol";
import {Seasons} from "../../src/Seasons.sol";
import {ReviewIMD} from "./IndependentAccounting.t.sol";

contract MetadataPerformanceReviewTest is Test {
    Canvas private canvas;
    Seasons private seasons;

    function setUp() public {
        canvas = new Canvas(address(this));
        ReviewIMD imd = new ReviewIMD();
        canvas.start(address(imd));
        canvas.credit(address(this), 4096);
        seasons = canvas.seasons();
        for (uint16 start; start < 4096; start += 50) {
            uint16 n = start + 50 > 4096 ? 4096 - start : 50;
            uint16[] memory ids = new uint16[](n);
            uint8[] memory cs = new uint8[](n);
            for (uint16 i; i < n; ++i) {
                ids[i] = start + i;
                cs[i] = uint8((start + i) % 16);
            }
            canvas.paint(ids, cs);
        }
        vm.warp(canvas.seasonStart() + 7 days);
        canvas.endSeason();
    }

    function test_ReviewDenseMetadataWithin32MillionGas() public {
        uint256 before = gasleft();
        (bool success, bytes memory returned) =
            address(seasons).staticcall{gas: 32_000_000}(abi.encodeCall(Seasons.tokenURI, (1)));
        uint256 used = before - gasleft();
        assertTrue(success, "dense metadata exceeded its 32M call budget");
        assertLe(used, 32_000_000);
        string memory uri = abi.decode(returned, (string));
        bytes memory encoded = bytes(uri);
        bytes memory prefix = bytes("data:application/json;base64,");
        for (uint256 i; i < prefix.length; ++i) {
            assertEq(encoded[i], prefix[i]);
        }
        assertGt(encoded.length, 10000);
        emit log_named_uint("dense tokenURI gas", used);
        emit log_named_uint("dense tokenURI bytes", encoded.length);
    }

    function test_ReviewPackedColourExtractionAcrossWholeCanvas() public view {
        bytes memory cs = canvas.coloursOf(1);
        assertEq(cs.length, 4096);
        for (uint256 i; i < 4096; ++i) {
            assertEq(uint8(cs[i]), i % 16);
        }
    }
}
