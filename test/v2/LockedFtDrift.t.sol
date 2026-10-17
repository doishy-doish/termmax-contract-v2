// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {DeployUtils} from "./utils/DeployUtils.sol";
import {JSONLoader} from "./utils/JSONLoader.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {
    ITermMaxMarketV2,
    ITermMaxMarket,
    TermMaxMarketV2,
    Constants,
    MarketErrors,
    MarketEvents
} from "contracts/v2/TermMaxMarketV2.sol";
import {ITermMaxOrder, TermMaxOrderV2, ISwapCallback, OrderEvents} from "contracts/v2/TermMaxOrderV2.sol";
import {
    VaultInitialParams,
    MarketConfig,
    MarketInitialParams,
    LoanConfig,
    OrderConfig,
    CurveCuts,
    IOracle
} from "contracts/v1/storage/TermMaxStorage.sol";
import {
    ITermMaxVaultV2,
    TermMaxVaultV2,
    VaultErrors,
    VaultEvents,
    VaultErrorsV2,
    VaultEventsV2,
    VaultConstants,
    OrderV2ConfigurationParams
} from "contracts/v2/vault/TermMaxVaultV2.sol";
import {VaultInitialParamsV2} from "contracts/v2/storage/TermMaxStorageV2.sol";
import {TermMaxFactoryV2} from "contracts/v2/factory/TermMaxFactoryV2.sol";
import {SwapUtils} from "./utils/SwapUtils.sol";

contract LockedFtDrift is Test {
    using JSONLoader for *;
    using SafeCast for *;

    DeployUtils.Res res;

    OrderConfig orderConfig;
    MarketConfig marketConfig;

    address deployer = vm.randomAddress();
    address curator = vm.randomAddress();
    address guardian = vm.randomAddress();
    address lper = vm.randomAddress();
    address treasurer = vm.randomAddress();
    string testdata;

    TermMaxVaultV2 vault;

    uint256 timelock = 86400;
    uint256 maxCapacity = 1000000e18;
    uint64 performanceFeeRate = 0.5e8;

    ITermMaxMarket market2;

    uint256 currentTime;
    uint32 maxLtv = 0.89e8;
    uint32 liquidationLtv = 0.9e8;
    VaultInitialParamsV2 initialParams;

    function setUp() public {
        vm.startPrank(deployer);
        testdata = vm.readFile(string.concat(vm.projectRoot(), "/test/testdata/testdata.json"));

        currentTime = vm.parseUint(vm.parseJsonString(testdata, ".currentTime"));
        vm.warp(currentTime);

        marketConfig = JSONLoader.getMarketConfigFromJson(treasurer, testdata, ".marketConfig");
        orderConfig = JSONLoader.getOrderConfigFromJson(testdata, ".orderConfig");
        marketConfig.maturity = uint64(currentTime + 90 days);
        res = DeployUtils.deployMarket(deployer, marketConfig, maxLtv, liquidationLtv);
        MarketConfig memory marketConfig2 = JSONLoader.getMarketConfigFromJson(treasurer, testdata, ".marketConfig");
        marketConfig2.maturity = uint64(currentTime + 180 days);
        TermMaxFactoryV2 factory =
            DeployUtils.deployMarketFactory(address(res.accessManager), address(res.whitelistManager));
        market2 = TermMaxMarketV2(
            factory.createMarket(
                DeployUtils.GT_ERC20,
                MarketInitialParams({
                    collateral: address(res.collateral),
                    debtToken: res.debt,
                    admin: deployer,
                    gtImplementation: address(0),
                    marketConfig: marketConfig2,
                    loanConfig: LoanConfig({
                        maxLtv: maxLtv,
                        liquidationLtv: liquidationLtv,
                        liquidatable: true,
                        oracle: IOracle(address(res.oracle))
                    }),
                    gtInitalParams: abi.encode(type(uint256).max),
                    tokenName: "test",
                    tokenSymbol: "test"
                }),
                0
            )
        );

        res.collateralOracle.updateRoundData(JSONLoader.getRoundDataFromJson(testdata, ".priceData.ETH_2000_DAI_1.eth"));
        res.debtOracle.updateRoundData(JSONLoader.getRoundDataFromJson(testdata, ".priceData.ETH_2000_DAI_1.dai"));

        uint256 amount = 10000e8;

        initialParams = VaultInitialParamsV2(
            deployer,
            curator,
            guardian,
            timelock,
            res.debt,
            IERC4626(address(0)),
            maxCapacity,
            "Vault-DAI",
            "Vault-DAI",
            performanceFeeRate,
            0
        );

        vault = DeployUtils.deployVault(res.vaultFactory, initialParams);
        vm.startPrank(deployer);

        vault.submitMarket(address(res.market), true);
        vault.submitMarket(address(market2), true);
        vm.warp(currentTime + timelock + 1);
        vault.acceptMarket(address(res.market));
        vault.acceptMarket(address(market2));
        vm.warp(currentTime);

        res.debt.mint(deployer, amount);
        res.debt.approve(address(vault), amount);
        vault.deposit(amount, deployer);

        OrderV2ConfigurationParams memory orderConfigParams = OrderV2ConfigurationParams({
            maxXtReserve: maxCapacity,
            virtualXtReserve: amount,
            originalVirtualXtReserve: 0,
            curveCuts: orderConfig.curveCuts
        });

        res.order = TermMaxOrderV2(address(vault.createOrder(res.market, orderConfigParams)));
        vm.stopPrank();
    }

    function test_lockedFtDrift_10d() public {
        vm.warp(currentTime + 10 days);
        fairBuyXt(10e8);
    }

    function test_lockedFtDrift_20d() public {
        vm.warp(currentTime + 20 days);
        fairBuyXt(10e8);
    }

    function test_lockedFtDrift_30d() public {
        vm.warp(currentTime + 30 days);
        fairBuyXt(10e8);
    }

    function fairBuyXt(uint128 tokenAmtIn) internal {
        (, uint256 pXt) = SwapUtils.getPrice(res);
        uint128 xtOut = uint128((uint256(tokenAmtIn) * Constants.DECIMAL_BASE) / pXt);
        xtOut = (xtOut * 98) / 100;
        address taker = vm.randomAddress();
        res.debt.mint(taker, tokenAmtIn);
        vm.startPrank(taker);
        res.debt.approve(address(res.order), tokenAmtIn);
        res.order.swapExactTokenToToken(res.debt, res.xt, taker, tokenAmtIn, xtOut, block.timestamp + 1 hours);
        vm.stopPrank();
    }

    function buyXt(uint128 tokenAmtIn, uint128 xtAmtOut) internal {
        address taker = vm.randomAddress();
        res.debt.mint(taker, tokenAmtIn);
        vm.startPrank(taker);
        res.debt.approve(address(res.order), tokenAmtIn);
        res.order.swapExactTokenToToken(res.debt, res.xt, taker, tokenAmtIn, xtAmtOut, block.timestamp + 1 hours);
        vm.stopPrank();
    }
}
