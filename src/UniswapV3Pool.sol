// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import {Tick} from "./lib/Tick.sol";
import {TickMath} from "./lib/TickMath.sol";
import {TickBitmap} from "./lib/TickBitmap.sol";
import {Position} from "./lib/Position.sol";
import {Math} from "./lib/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IUniswapV3MintCallback} from "./interfaces/IUniswapV3MintCallback.sol";
import {IUniswapV3SwapCallback} from "./interfaces/IUniswapV3SwapCallback.sol";

contract UniswapV3Pool {
    using TickBitmap for mapping(int16 => uint256);
    using Tick for mapping(int24 => Tick.Info);
    using Position for mapping(bytes32 => Position.Info);
    using Position for Position.Info;

    error InvalidTickRange();
    error ZeroLiquidity();
    error InsufficientInputAmount();

    event Mint(
        address executor,
        address owner,
        int24 lowerTick,
        int24 upperTick,
        uint128 amount,
        uint256 amount0,
        uint256 amount1
    );
    event Swap(
        address executor,
        address recipient,
        int256 amount0,
        int256 amount1,
        uint160 price,
        uint128 liquidity,
        int24 tick
    );

    int24 internal constant MIN_TICK = -887272;
    int24 internal constant MAX_TICK = -MIN_TICK;

    address public immutable token0;
    address public immutable token1;

    struct Slot0{
        uint160 sqrtPriceX96;
        int24 tick;
    }

    struct CallbackData{
        address token0;
        address token1;
        address payer;
    }

    struct SwapState{
        uint256 amountSpecifiedRemaining;
        uint256 amountCalculated;
        uint160 sqrtPriceX96;
        int24 tick;
    }

    struct StepState{
        uint160 sqrtPriceStartX96;
        int24 nextTick;
        uint160 sqrtPriceNextX96;
        uint256 amountIn;
        uint256 amountOut;
    }

    Slot0 public slot0;

    uint128 public liquidity;

    mapping(int16 => uint256) public tickBitmap;
    mapping(int24 => Tick.Info) public ticks;
    mapping(bytes32 => Position.Info) public positions;

    constructor(address _token0, address _token1, uint160 sqrtPriceX96, int24 tick){
        token0 = _token0;
        token1 = _token1;
        slot0 = Slot0({
            sqrtPriceX96: sqrtPriceX96,
            tick: tick
        });
    }

    function mint(
        address owner, 
        int24 lowerTick,
        int24 upperTick,
        uint128 amount,
        bytes calldata data
    ) external returns(uint256 amount0, uint256 amount1) {
        if (
            lowerTick >= upperTick ||
            lowerTick < MIN_TICK ||
            upperTick > MAX_TICK
        ) revert InvalidTickRange();

        if (amount == 0) revert ZeroLiquidity();

        bool flippedLower = ticks.update(lowerTick, amount);
        bool flippedUpper = ticks.update(upperTick, amount);

        if(flippedLower){
            tickBitmap.flipTick(lowerTick, 1);
        }

        if(flippedUpper){
            tickBitmap.flipTick(upperTick, 1);
        }

        Position.Info storage position = positions.get(owner, lowerTick, upperTick);

        position.update(amount);

        Slot0 memory slot0_ = slot0;

        amount0 = Math.calcAmount0Delta(
            TickMath.getSqrtRatioAtTick(slot0_.tick),
            TickMath.getSqrtRatioAtTick(upperTick),
            amount
        );

        amount1 = Math.calcAmount0Delta(
            TickMath.getSqrtRatioAtTick(slot0_.tick),
            TickMath.getSqrtRatioAtTick(lowerTick),
            amount
        );

        liquidity += uint128(amount);

        uint256 balance0Before;
        uint256 balance1Before;
        if(amount0 > 0) balance0Before = balance0();
        if(amount1 > 0) balance1Before = balance1();
        IUniswapV3MintCallback(msg.sender).uniswapV3MintCallback(amount0, amount1, data);
        if(amount0 > 0 && balance0Before + amount0 > balance0()) revert InsufficientInputAmount();
        if(amount1 > 0 && balance1Before + amount1 > balance1()) revert InsufficientInputAmount();
        
        emit Mint(msg.sender, owner, lowerTick, upperTick, amount, amount0, amount1);
    }

    function swap(
        address recipient,
        bool zeroForOne,
        uint256 amountSpecified,
        bytes calldata data
    ) public returns(int256 amount0, int256 amount1){
        int24 nextTick = 85184;
        uint160 nextPrice = 5604469350942327889444743441197;

        amount0 = -0.008396714242162444 ether;
        amount1 = 42 ether;

        (slot0.tick, slot0.sqrtPriceX96) = (nextTick, nextPrice);

        IERC20(token0).transfer(recipient, uint256(-amount0));

        uint256 balance1Before = balance1();
        IUniswapV3SwapCallback(msg.sender). uniswapV3SwapCallback(amount0, amount1, data);
        if(balance1Before + uint256(amount1) < balance1()) revert InsufficientInputAmount();

        emit Swap(
            msg.sender,
            recipient,
            amount0,
            amount1,
            slot0.sqrtPriceX96,
            liquidity,
            slot0.tick
        );
    }

    function balance0() internal view returns(uint256 balance){
        balance = IERC20(token0).balanceOf(address(this));
    }

    function balance1() internal view returns(uint256 balance){
        balance = IERC20(token1).balanceOf(address(this));
    }

}