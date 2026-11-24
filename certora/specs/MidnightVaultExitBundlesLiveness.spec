// SPDX-License-Identifier: MIT

// Bounded arithmetic liveness properties for MidnightVaultExitBundlesV1.
// Gas is intentionally out of scope.

definition maxTokenSupply() returns uint256 = 10 ^ 32;
definition maxSettlementFee() returns uint256 = 5 * 10 ^ 15;

persistent ghost assetOf(address) returns address;
persistent ghost tokenBalance(address, address) returns uint256;
persistent ghost mathint flashLoanCalls;

methods {
    function initiator() external returns (address) envfree;
    function MIDNIGHT() external returns (address) envfree;
    function _.isAdapter(address) external => returnTrue() expect(bool);
    function _.midnight() external => configuredMidnight() expect(address);
    function _.marketIdsLength() external => returnZero() expect(uint256);
    function _.asset() external => assetOf(calledContract) expect(address);
    function _.balanceOf(address account) external => tokenBalance(calledContract, account) expect(uint256);
    function _.withdraw(uint256, address, address) external => returnZero() expect(uint256);
    function _.flashLoan(address, uint256, bytes) external => recordFlashLoan() expect void;
    function SafeTransferLib.safeTransfer(address, address, uint256) internal => safeTransferSucceeds();
}

function returnTrue() returns bool {
    return true;
}

function returnZero() returns uint256 {
    return 0;
}

function configuredMidnight() returns address {
    return 1;
}

function recordFlashLoan() {
    flashLoanCalls = flashLoanCalls + 1;
}

function safeTransferSucceeds() {}

rule fullyIdleExitDoesNotRevert(
    env e,
    address vault,
    address adapter,
    uint256 exitAssets,
    uint256 deadline
) {
    require e.msg.sender != currentContract;
    require e.msg.value == 0;
    require vault != 0 && vault != currentContract;
    require adapter != 0 && adapter != currentContract && adapter != vault;
    require assetOf(vault) != 0 && assetOf(vault) != currentContract;
    require assetOf(vault) != vault && assetOf(vault) != adapter;
    require MIDNIGHT() == configuredMidnight();
    require initiator() == 0;
    require e.block.timestamp <= deadline;
    require exitAssets <= tokenBalance(assetOf(vault), vault);

    mathint flashLoanCallsBefore = flashLoanCalls;
    redeemFullyIdle@withrevert(e, vault, adapter, exitAssets, deadline);

    assert !lastReverted;
    assert flashLoanCalls == flashLoanCallsBefore;
    assert initiator() == 0;
}

rule proRataThreeMarketsConservesAssets(
    env e,
    uint256 first,
    uint256 second,
    uint256 third,
    uint256 assets
) {
    require e.msg.value == 0;
    require first <= maxTokenSupply();
    require second <= maxTokenSupply();
    require third <= maxTokenSupply();
    require assets > 0;
    require assets <= first + second + third;

    uint256 firstAmount;
    uint256 secondAmount;
    uint256 thirdAmount;
    firstAmount, secondAmount, thirdAmount = distributeThree@withrevert(e, first, second, third, assets);

    assert !lastReverted;
    assert firstAmount + secondAmount + thirdAmount == assets;
    assert firstAmount <= first;
    assert secondAmount <= second;
    assert thirdAmount <= third;
}

rule chunkMakesProgress(
    env e,
    uint256 seed,
    uint256 feeRate,
    uint256 assets
) {
    require e.msg.value == 0;
    require seed >= 2;
    require seed <= maxTokenSupply();
    require feeRate <= maxSettlementFee();
    require assets > 0;
    require assets <= maxTokenSupply();

    uint256 chunkAssets;
    uint256 fee;
    uint256 funding;
    chunkAssets, fee, funding = chunk@withrevert(e, seed, feeRate, assets);

    assert !lastReverted;
    assert chunkAssets > 0;
    assert chunkAssets <= assets;
    assert assets - chunkAssets < assets;
    assert funding == chunkAssets + fee;
    assert funding <= seed;
}
