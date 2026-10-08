// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {ICanvas} from "./interfaces/IPlace.sol";

/// @notice Immutable artwork, English auctions, and final-pixel-owner distributions.
contract Seasons is ERC721, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Strings for uint256;

    ICanvas public immutable canvas;
    uint256 public totalPaid;
    /// @notice Outstanding bids, withdrawable refunds and unclaimed artist payouts.
    uint256 public totalEscrow;
    mapping(address => uint256) public pendingRefunds;

    struct Auction {
        uint64 end;
        uint16 occupied;
        uint32 painters;
        uint64 paints;
        address topPainter;
        address bidder;
        bool finalized;
        uint256 highBid;
        uint256 pot;
        uint256 payout;
        uint256 paid;
    }
    mapping(uint256 => Auction) public auctions;
    mapping(uint256 => mapping(uint256 => uint256)) public claimedBitmap;

    error Unauthorized();
    error AuctionClosed();
    error BidTooLow();
    error NotReady();
    error AlreadyClaimed();
    error UnsupportedToken();

    event AuctionOpened(uint256 indexed season, uint256 end, uint256 pot, uint16 occupied);
    event Bid(uint256 indexed season, address indexed bidder, uint256 amount, uint256 end);
    event RefundCredited(address indexed bidder, uint256 amount);
    event RefundWithdrawn(address indexed bidder, uint256 amount);
    event Finalized(uint256 indexed season, address indexed recipient, uint256 payout);
    event Claimed(uint256 indexed season, address indexed artist, uint256 amount);

    constructor(address canvas_) ERC721("imd/place seasons", "i/p seasons") {
        require(canvas_ != address(0), "canvas required");
        canvas = ICanvas(canvas_);
    }

    function open(
        uint256 id,
        uint256 pot,
        uint16 occupied,
        uint32 painters,
        uint64 paints,
        address topPainter
    ) external {
        if (msg.sender != address(canvas)) revert Unauthorized();
        auctions[id] = Auction({
            end: uint64(block.timestamp + 1 days),
            occupied: occupied,
            painters: painters,
            paints: paints,
            topPainter: topPainter,
            bidder: address(0),
            finalized: false,
            highBid: 0,
            pot: pot,
            payout: 0,
            paid: 0
        });
        _mint(address(this), id);
        emit AuctionOpened(id, block.timestamp + 1 days, pot, occupied);
    }

    /// @dev First bid is one atomic unit. Subsequent raises round UP to at least 5%.
    function minimumBid(uint256 id) public view returns (uint256) {
        Auction storage a = auctions[id];
        if (a.end == 0 || a.finalized || block.timestamp >= a.end || a.occupied == 0) revert AuctionClosed();
        if (a.highBid == 0) return 1;
        return a.highBid + (a.highBid + 19) / 20;
    }

    /// @notice Unbid pots must reach the immediately following season before it can freeze.
    function rolloverResolved(uint256 id) external view returns (bool) {
        Auction storage a = auctions[id];
        return a.finalized || a.highBid > 0;
    }

    function bid(uint256 id, uint256 amount) external nonReentrant {
        if (amount < minimumBid(id)) revert BidTooLow();
        Auction storage a = auctions[id];
        address previous = a.bidder;
        uint256 refund = a.highBid;
        a.bidder = msg.sender;
        a.highBid = amount;
        totalEscrow += amount;
        if (refund > 0) {
            pendingRefunds[previous] += refund;
            emit RefundCredited(previous, refund);
        }
        if (block.timestamp >= uint256(a.end) - 10 minutes) a.end += 10 minutes;
        emit Bid(id, msg.sender, amount, a.end);
        IERC20 token = IERC20(canvas.imd());
        token.safeTransferFrom(msg.sender, address(this), amount);
        if (token.balanceOf(address(this)) < totalEscrow) revert UnsupportedToken();
    }

    /// @notice Outbid IMD is immediately withdrawable, independently of any auction.
    /// @dev A failed transfer preserves this caller's credit without blocking another bid.
    function withdrawRefund() external nonReentrant returns (uint256 amount) {
        amount = pendingRefunds[msg.sender];
        pendingRefunds[msg.sender] = 0;
        totalEscrow -= amount;
        emit RefundWithdrawn(msg.sender, amount);
        IERC20 token = IERC20(canvas.imd());
        if (amount > 0) token.safeTransfer(msg.sender, amount);
        if (token.balanceOf(address(this)) < totalEscrow) revert UnsupportedToken();
    }

    function finalize(uint256 id) external nonReentrant {
        Auction storage a = auctions[id];
        if (a.end == 0 || a.finalized || block.timestamp < a.end) revert NotReady();
        a.finalized = true;
        if (a.highBid > 0) {
            a.payout = a.highBid + a.pot;
            totalEscrow += a.pot;
            emit Finalized(id, a.bidder, a.payout);
            // No receiver callback: a winning contract cannot block artist settlement.
            _transfer(address(this), a.bidder, id);
            uint256 released = canvas.releasePot(id);
            require(released == a.pot, "pot mismatch");
            if (IERC20(canvas.imd()).balanceOf(address(this)) < totalEscrow) revert UnsupportedToken();
        } else {
            emit Finalized(id, a.topPainter, 0);
            // A wholly blank season has no top painter; its NFT remains in escrow forever.
            if (a.topPainter != address(0)) _transfer(address(this), a.topPainter, id);
            canvas.rollPot(id);
        }
    }

    /// @notice Claim up to 50 frozen pixels. No iteration over other artists is required.
    function claim(uint256 id, uint16[] calldata ids) external nonReentrant returns (uint256 amount) {
        Auction storage a = auctions[id];
        if (!a.finalized || a.highBid == 0) revert NotReady();
        uint16[] memory ranks = canvas.frozenRanks(id, msg.sender, ids);
        uint256 each = a.payout / a.occupied;
        uint256 remainder = a.payout % a.occupied;
        amount = 0;
        for (uint256 i = 0; i < ids.length; ++i) {
            uint256 word = ids[i] >> 8;
            uint256 bit = uint256(1) << (ids[i] & 255);
            if (claimedBitmap[id][word] & bit != 0) revert AlreadyClaimed();
            claimedBitmap[id][word] |= bit;
            amount += each;
            if (ranks[i] <= remainder) ++amount;
        }
        a.paid += amount;
        totalPaid += amount;
        totalEscrow -= amount;
        emit Claimed(id, msg.sender, amount);
        if (amount > 0) IERC20(canvas.imd()).safeTransfer(msg.sender, amount);
        if (IERC20(canvas.imd()).balanceOf(address(this)) < totalEscrow) revert UnsupportedToken();
    }

    function svg(uint256 id) public view returns (string memory) {
        _requireOwned(id);
        bytes memory colours = canvas.coloursOf(id);
        uint24[16] memory palette = canvas.getPalette();
        uint16[16] memory runs;
        for (uint256 y = 0; y < 64; ++y) {
            uint256 x = 0;
            while (x < 64) {
                uint8 c = uint8(colours[y * 64 + x]);
                uint256 end = x + 1;
                while (end < 64 && colours[y * 64 + end] == bytes1(c)) ++end;
                if (c < 16) ++runs[c];
                x = end;
            }
        }
        bytes[16] memory paths;
        uint256[16] memory lengths;
        for (uint256 c = 0; c < 16; ++c) {
            paths[c] = new bytes(uint256(runs[c]) * 18);
        }
        for (uint256 y = 0; y < 64; ++y) {
            uint256 x = 0;
            while (x < 64) {
                uint8 c = uint8(colours[y * 64 + x]);
                uint256 end = x + 1;
                while (end < 64 && colours[y * 64 + end] == bytes1(c)) ++end;
                if (c < 16) lengths[c] = _rectangle(paths[c], lengths[c], x, y, end - x);
                x = end;
            }
        }
        bytes memory out = new bytes(4096 * 18 + 1024);
        uint256 pos = _append(
            out,
            0,
            bytes(
                '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64" shape-rendering="crispEdges"><path fill="#181425" d="M0 0h64v64H0z"/>'
            )
        );
        for (uint256 c = 0; c < 16; ++c) {
            if (lengths[c] == 0) continue;
            bytes memory path = paths[c];
            uint256 length = lengths[c];
            assembly ("memory-safe") { mstore(path, length) }
            bytes memory full = bytes(Strings.toHexString(uint256(palette[c]), 3));
            bytes memory rgb = new bytes(7);
            rgb[0] = "#";
            for (uint256 j = 1; j < 7; ++j) {
                rgb[j] = full[j + 1];
            }
            pos = _append(out, pos, abi.encodePacked('<path fill="', rgb, '" d="'));
            pos = _append(out, pos, path);
            pos = _append(out, pos, bytes('"/>'));
        }
        pos = _append(out, pos, bytes("</svg>"));
        assembly ("memory-safe") { mstore(out, pos) }
        return string(out);
    }

    function _rectangle(bytes memory out, uint256 pos, uint256 x, uint256 y, uint256 width)
        private
        pure
        returns (uint256)
    {
        // Only the bounded 64x64 renderer calls this: x,y <=63, width <=64.
        // Each run reserves 18 bytes; its Mxx yyhwwv1Hxxz command needs at most 15.
        assembly ("memory-safe") {
            function writeDecimal(at, value) -> end {
                if gt(value, 9) {
                    mstore8(at, add(48, div(value, 10)))
                    at := add(at, 1)
                }
                mstore8(at, add(48, mod(value, 10)))
                end := add(at, 1)
            }
            let start := add(out, 32)
            let at := add(start, pos)
            mstore8(at, 77)
            at := writeDecimal(add(at, 1), x)
            mstore8(at, 32)
            at := writeDecimal(add(at, 1), y)
            mstore8(at, 104)
            at := writeDecimal(add(at, 1), width)
            mstore8(at, 118)
            mstore8(add(at, 1), 49)
            mstore8(add(at, 2), 72)
            at := writeDecimal(add(at, 3), x)
            mstore8(at, 122)
            pos := sub(add(at, 1), start)
        }
        return pos;
    }

    function _append(bytes memory dest, uint256 pos, bytes memory part) private pure returns (uint256) {
        require(pos + part.length <= dest.length, "SVG buffer");
        assembly ("memory-safe") { mcopy(add(add(dest, 32), pos), add(part, 32), mload(part)) }
        return pos + part.length;
    }

    function tokenURI(uint256 id) public view override returns (string memory) {
        Auction storage a = auctions[id];
        bytes memory json = abi.encodePacked(
            '{"name":"imd/place season ',
            id.toString(),
            '","external_url":"https://x.com/imdplace","image":"data:image/svg+xml;base64,',
            Base64.encode(bytes(svg(id))),
            '","attributes":[{"trait_type":"season","value":',
            id.toString(),
            '},{"trait_type":"painters","value":',
            uint256(a.painters).toString(),
            '},{"trait_type":"paints","value":',
            uint256(a.paints).toString(),
            "}]}"
        );
        return string.concat("data:application/json;base64,", Base64.encode(json));
    }
}
