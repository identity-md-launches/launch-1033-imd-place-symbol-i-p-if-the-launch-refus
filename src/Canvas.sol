// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPlaceHook} from "./interfaces/IPlace.sol";
import {Seasons} from "./Seasons.sol";

/// @notice Paint balances, immutable seasonal canvases and trade-fee accounting.
contract Canvas is ReentrancyGuard {
    uint256 public constant SCALE = 1e24;
    uint256 public constant DURATION = 7 days;
    address public constant TREASURY = 0xA7e99BB7155D7477E0C838E201b16E62B9c0b5Ac;
    address public immutable hook;
    Seasons public immutable seasons;
    address public imd;
    uint256 public currentSeason;
    uint256 public seasonStart;
    uint256 public accumulator;
    uint256 public divisionRemainder;
    uint256 public seasonPot;
    uint256 public treasuryCredit;
    uint256 public totalFees;
    uint256 public totalArtistFees;
    uint256 public totalPaid;
    uint256 public totalTreasuryPaid;

    // Exactly 256 bits: one storage slot per pixel per season.
    struct Pixel {
        address owner;
        uint8 colour;
        uint32 paints;
        uint40 windowStart;
        uint16 rank;
    }

    struct Account {
        uint256 scaledCredit;
        uint256 checkpoint;
        uint256 season;
    }

    struct Stats {
        uint16 occupied;
        uint32 painters;
        uint64 paints;
        address topPainter;
        uint64 topPaints;
    }

    mapping(uint256 => mapping(uint16 => Pixel)) public pixels;
    mapping(uint256 => mapping(address => uint16)) public owned;
    mapping(uint256 => mapping(address => uint64)) public painted;
    mapping(uint256 => Stats) public stats;
    mapping(address => uint256) public drops;
    mapping(address => Account) public accounts;
    mapping(uint256 => uint256) public finalAccumulator;
    mapping(uint256 => uint256) public frozenPot;
    uint24[16] public palette = [
        uint24(0x181425),
        0xffffff,
        0xc0cbdc,
        0x5a6988,
        0xff0044,
        0xff8426,
        0xffd635,
        0x63c74d,
        0x009e8f,
        0x22d3ee,
        0x0099db,
        0x3e52f5,
        0x8b46ff,
        0xf472b6,
        0x8f563b,
        0xffccaa
    ];

    error Unauthorized();
    error InvalidBatch();
    error InvalidPixel();
    error InsufficientPaint();
    error SeasonNotReady();
    error NotStarted();
    error InvalidSeason();
    error BudgetExceeded();
    error PreviousAuctionPending();

    event Started(address indexed imd, uint256 timestamp);
    event PaintCredited(address indexed buyer, uint256 drops);
    event Painted(
        uint256 indexed season, uint16 indexed pixel, address indexed artist, uint8 colour, uint256 cost
    );
    event FeeRecorded(uint256 owners, uint256 pot, uint256 treasury);
    event Claimed(address indexed artist, uint256 amount);
    event TreasuryClaimed(uint256 amount);
    event SeasonEnded(uint256 indexed season, uint16 occupied, uint256 pot);
    event PotReleased(uint256 indexed season, uint256 amount);
    event PotCarried(uint256 indexed fromSeason, uint256 indexed toSeason, uint256 amount);

    constructor(address hook_) {
        require(hook_ != address(0), "hook required");
        hook = hook_;
        seasons = new Seasons(address(this));
    }

    modifier onlyHook() {
        if (msg.sender != hook) revert Unauthorized();
        _;
    }
    modifier onlySeasons() {
        if (msg.sender != address(seasons)) revert Unauthorized();
        _;
    }

    function start(address imd_) external onlyHook {
        if (currentSeason != 0 || imd_.code.length == 0) revert InvalidSeason();
        imd = imd_;
        currentSeason = 1;
        seasonStart = block.timestamp;
        emit Started(imd_, block.timestamp);
    }

    function credit(address buyer, uint256 amount) external onlyHook {
        if (buyer == address(0) || currentSeason == 0) revert NotStarted();
        drops[buyer] += amount;
        emit PaintCredited(buyer, amount);
    }

    /// @dev Called only after the hook mints matching, backed PoolManager claims.
    function recordFee(uint256 fee, uint256 baseFee) external onlyHook {
        require(baseFee <= fee && currentSeason != 0, "invalid fee");
        uint256 artists = Math.mulDiv(baseFee, 67, 100);
        uint256 treasury = Math.mulDiv(baseFee, 8, 100);
        uint256 pot = fee - artists - treasury;
        uint256 count = stats[currentSeason].occupied;
        if (count == 0) {
            pot += artists;
            artists = 0;
        } else {
            uint256 numerator = artists * SCALE + divisionRemainder;
            accumulator += numerator / count;
            divisionRemainder = numerator % count;
        }
        totalFees += fee;
        totalArtistFees += artists;
        treasuryCredit += treasury;
        seasonPot += pot;
        emit FeeRecorded(artists, pot, treasury);
    }

    function price(uint16 id) public view returns (uint256) {
        if (id >= 4096) revert InvalidPixel();
        Pixel memory p = pixels[currentSeason][id];
        if (p.owner == address(0) || block.timestamp >= uint256(p.windowStart) + 1 days) return 1;
        return uint256(1) << (p.paints > 10 ? 10 : p.paints);
    }

    function paint(uint16[] calldata ids, uint8[] calldata colours) external nonReentrant {
        _paint(ids, colours, type(uint256).max);
    }

    /// @notice A bounded-price alternative for the site's transaction review.
    function paintWithLimit(uint16[] calldata ids, uint8[] calldata colours, uint256 maxDrops)
        external
        nonReentrant
    {
        _paint(ids, colours, maxDrops);
    }

    function _paint(uint16[] calldata ids, uint8[] calldata colours, uint256 maxDrops) internal {
        if (currentSeason == 0) revert NotStarted();
        // Once the deadline arrives nobody can change the image awaiting its permissionless freeze.
        if (block.timestamp >= seasonStart + DURATION) revert SeasonNotReady();
        if (ids.length == 0 || ids.length > 50 || ids.length != colours.length) revert InvalidBatch();
        uint256 spent = 0;
        Stats storage s = stats[currentSeason];
        for (uint256 i = 0; i < ids.length; ++i) {
            if (ids[i] >= 4096 || colours[i] >= 16) revert InvalidPixel();
            // Duplicate entries are rejected, not charged twice by accident.
            for (uint256 j = 0; j < i; ++j) {
                if (ids[j] == ids[i]) revert InvalidBatch();
            }
            Pixel storage p = pixels[currentSeason][ids[i]];
            uint256 cost = price(ids[i]);
            spent += cost;
            address previous = p.owner;
            if (previous != msg.sender) {
                if (previous != address(0)) {
                    _settle(previous);
                    --owned[currentSeason][previous];
                } else {
                    p.rank = ++s.occupied;
                }
                _settle(msg.sender);
                ++owned[currentSeason][msg.sender];
                p.owner = msg.sender;
            }
            if (previous == address(0) || block.timestamp >= uint256(p.windowStart) + 1 days) {
                p.windowStart = uint40(block.timestamp);
                p.paints = 1;
            } else {
                ++p.paints;
            }
            p.colour = colours[i];
            emit Painted(currentSeason, ids[i], msg.sender, colours[i], cost);
        }
        if (spent > maxDrops) revert BudgetExceeded();
        if (spent > drops[msg.sender]) revert InsufficientPaint();
        drops[msg.sender] -= spent;
        uint64 previousPaints = painted[currentSeason][msg.sender];
        if (previousPaints == 0) ++s.painters;
        uint64 newPaints = previousPaints + uint64(ids.length);
        painted[currentSeason][msg.sender] = newPaints;
        s.paints += uint64(ids.length);
        if (newPaints > s.topPaints) {
            s.topPaints = newPaints;
            s.topPainter = msg.sender;
        }
    }

    function _settle(address artist) internal {
        Account storage a = accounts[artist];
        if (a.season != 0) {
            uint256 end = a.season == currentSeason ? accumulator : finalAccumulator[a.season];
            a.scaledCredit += (end - a.checkpoint) * owned[a.season][artist];
        }
        a.season = currentSeason;
        a.checkpoint = accumulator;
    }

    function claimable(address artist) external view returns (uint256) {
        Account memory a = accounts[artist];
        uint256 accrued = a.scaledCredit;
        if (a.season != 0) {
            uint256 end = a.season == currentSeason ? accumulator : finalAccumulator[a.season];
            accrued += (end - a.checkpoint) * owned[a.season][artist];
        }
        return accrued / SCALE;
    }

    function claim() external nonReentrant returns (uint256 amount) {
        _settle(msg.sender);
        Account storage a = accounts[msg.sender];
        amount = a.scaledCredit / SCALE;
        a.scaledCredit %= SCALE;
        totalPaid += amount;
        emit Claimed(msg.sender, amount);
        if (amount > 0) IPlaceHook(hook).pay(msg.sender, amount);
    }

    function claimTreasury() external nonReentrant returns (uint256 amount) {
        amount = treasuryCredit;
        treasuryCredit = 0;
        totalTreasuryPaid += amount;
        emit TreasuryClaimed(amount);
        if (amount > 0) IPlaceHook(hook).pay(TREASURY, amount);
    }

    function endSeason() external nonReentrant {
        if (currentSeason == 0 || block.timestamp < seasonStart + DURATION) revert SeasonNotReady();
        uint256 id = currentSeason;
        if (id > 1 && !seasons.rolloverResolved(id - 1)) revert PreviousAuctionPending();
        uint256 pot = seasonPot;
        Stats memory s = stats[id];
        frozenPot[id] = pot;
        finalAccumulator[id] = accumulator;
        currentSeason = id + 1;
        seasonStart = block.timestamp;
        seasonPot = 0;
        accumulator = 0;
        emit SeasonEnded(id, s.occupied, pot);
        seasons.open(id, pot, s.occupied, s.painters, s.paints, s.topPainter);
    }

    function releasePot(uint256 id) external onlySeasons nonReentrant returns (uint256 amount) {
        amount = frozenPot[id];
        frozenPot[id] = 0;
        emit PotReleased(id, amount);
        if (amount > 0) IPlaceHook(hook).pay(address(seasons), amount);
    }

    function rollPot(uint256 id) external onlySeasons nonReentrant {
        uint256 amount = frozenPot[id];
        frozenPot[id] = 0;
        seasonPot += amount;
        emit PotCarried(id, currentSeason, amount);
    }

    function frozenRanks(uint256 id, address artist, uint16[] calldata ids)
        external
        view
        returns (uint16[] memory ranks)
    {
        if (id == 0 || id >= currentSeason || ids.length == 0 || ids.length > 50) revert InvalidSeason();
        ranks = new uint16[](ids.length);
        for (uint256 i = 0; i < ids.length; ++i) {
            if (ids[i] >= 4096) revert InvalidPixel();
            Pixel memory p = pixels[id][ids[i]];
            if (p.owner != artist || artist == address(0)) revert Unauthorized();
            ranks[i] = p.rank;
        }
    }

    /// @notice Empty pixels are encoded as 0xff, preserving palette colour zero.
    function coloursOf(uint256 id) external view returns (bytes memory data) {
        if (id == 0 || id > currentSeason) revert InvalidSeason();
        data = new bytes(4096);
        for (uint16 i = 0; i < 4096; ++i) {
            Pixel storage p = pixels[id][i];
            // owner occupies bits 0..159 and colour 160..167 of the one-slot Pixel.
            // i is bounded by both the loop and the 4096-byte allocation.
            assembly ("memory-safe") {
                let packed := sload(p.slot)
                let c := 255
                if and(packed, 0xffffffffffffffffffffffffffffffffffffffff) {
                    c := and(shr(160, packed), 255)
                }
                mstore8(add(add(data, 32), i), c)
            }
        }
    }

    function pixelPage(uint256 id, uint16 start_, uint16 count) external view returns (Pixel[] memory page) {
        if (count > 256 || uint256(start_) + count > 4096) revert InvalidBatch();
        page = new Pixel[](count);
        for (uint16 i = 0; i < count; ++i) {
            page[i] = pixels[id][start_ + i];
        }
    }

    function getPalette() external view returns (uint24[16] memory) {
        return palette;
    }
}
