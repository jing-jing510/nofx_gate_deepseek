package trader

import (
	"context"
	"fmt"
	"log"
	"math"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/antihax/optional"
	gateapi "github.com/gateio/gateapi-go/v6"
)

// GateTrader Gate.io交易器
type GateTrader struct {
	client      *gateapi.APIClient
	ctx         context.Context
	settle      string // 结算货币，通常是"usdt"
	cacheDuration time.Duration

	// 余额缓存
	cachedBalance     map[string]interface{}
	balanceCacheTime  time.Time
	balanceCacheMutex sync.RWMutex

	// 持仓缓存
	cachedPositions     []map[string]interface{}
	positionsCacheTime  time.Time
	positionsCacheMutex sync.RWMutex

	// 合约信息缓存（用于获取精度）
	contractCache     map[string]*gateapi.Contract
	contractCacheMutex sync.RWMutex
}

// NewGateTrader 创建Gate交易器
func NewGateTrader(apiKey, secretKey string, testnet bool) (*GateTrader, error) {
	// 清理密钥：去除前后空格和换行符
	apiKey = strings.TrimSpace(apiKey)
	secretKey = strings.TrimSpace(secretKey)
	
	// 验证密钥不为空
	if apiKey == "" {
		return nil, fmt.Errorf("Gate.io API Key 不能为空")
	}
	if secretKey == "" {
		return nil, fmt.Errorf("Gate.io Secret Key 不能为空")
	}
	
	cfg := gateapi.NewConfiguration()
	
	// 根据testnet选择API地址
	if testnet {
		cfg.BasePath = "https://api-testnet.gateapi.io/api/v4" // Gate.io测试网API地址
	} else {
		cfg.BasePath = "https://api.gateio.ws/api/v4" // Gate.io主网API地址
	}
	
	client := gateapi.NewAPIClient(cfg)

	ctx := context.WithValue(context.Background(), gateapi.ContextGateAPIV4, gateapi.GateAPIV4{
		Key:    apiKey,
		Secret: secretKey,
	})

	trader := &GateTrader{
		client:         client,
		ctx:            ctx,
		settle:         "usdt",
		cacheDuration:  15 * time.Second,
		contractCache:  make(map[string]*gateapi.Contract),
	}

	log.Printf("✓ Gate.io交易器初始化成功 (testnet=%v, API Key前8位: %s...)", testnet, apiKey[:min(8, len(apiKey))])
	return trader, nil
}

// min 辅助函数
func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}

// GetBalance 获取账户余额（带缓存）
func (t *GateTrader) GetBalance() (map[string]interface{}, error) {
	// 先检查缓存是否有效
	t.balanceCacheMutex.RLock()
	if t.cachedBalance != nil && time.Since(t.balanceCacheTime) < t.cacheDuration {
		cacheAge := time.Since(t.balanceCacheTime)
		t.balanceCacheMutex.RUnlock()
		log.Printf("✓ 使用缓存的账户余额（缓存时间: %.1f秒前）", cacheAge.Seconds())
		return t.cachedBalance, nil
	}
	t.balanceCacheMutex.RUnlock()

	// 缓存过期或不存在，调用API
	log.Printf("🔄 缓存过期，正在调用Gate.io API获取账户余额...")
	account, _, err := t.client.FuturesApi.ListFuturesAccounts(t.ctx, t.settle)
	if err != nil {
		// 详细错误信息
		if gateErr, ok := err.(gateapi.GateAPIError); ok {
			log.Printf("❌ Gate.io API调用失败: label: %s, message: %s", gateErr.Label, gateErr.Message)
			if gateErr.Label == "INVALID_KEY" {
				return nil, fmt.Errorf("Gate.io API密钥无效，请检查：1) API Key是否正确 2) Secret Key是否正确 3) API权限是否包含合约交易权限: %w", err)
			}
		} else {
			log.Printf("❌ Gate.io API调用失败: %v", err)
		}
		return nil, fmt.Errorf("获取账户信息失败: %w", err)
	}

	result := make(map[string]interface{})
	totalWalletBalance, _ := strconv.ParseFloat(account.Total, 64)
	unrealizedProfit, _ := strconv.ParseFloat(account.UnrealisedPnl, 64)
	availableBalance, _ := strconv.ParseFloat(account.Available, 64)

	// Gate.io的Total = 总资产（包含未实现盈亏）
	// 为了兼容auto_trader.go的逻辑，需要拆分出钱包余额
	walletBalance := totalWalletBalance - unrealizedProfit

	result["totalWalletBalance"] = walletBalance
	result["availableBalance"] = availableBalance
	result["totalUnrealizedProfit"] = unrealizedProfit

	log.Printf("✓ Gate.io账户: 总净值=%.2f (钱包%.2f+未实现%.2f), 可用=%.2f",
		totalWalletBalance, walletBalance, unrealizedProfit, availableBalance)

	// 更新缓存
	t.balanceCacheMutex.Lock()
	t.cachedBalance = result
	t.balanceCacheTime = time.Now()
	t.balanceCacheMutex.Unlock()

	return result, nil
}

// GetPositions 获取所有持仓（带缓存）
func (t *GateTrader) GetPositions() ([]map[string]interface{}, error) {
	// 先检查缓存是否有效
	t.positionsCacheMutex.RLock()
	if t.cachedPositions != nil && time.Since(t.positionsCacheTime) < t.cacheDuration {
		cacheAge := time.Since(t.positionsCacheTime)
		t.positionsCacheMutex.RUnlock()
		log.Printf("✓ 使用缓存的持仓信息（缓存时间: %.1f秒前）", cacheAge.Seconds())
		return t.cachedPositions, nil
	}
	t.positionsCacheMutex.RUnlock()

	// 缓存过期或不存在，调用API
	log.Printf("🔄 缓存过期，正在调用Gate.io API获取持仓信息...")

	// Gate.io需要先获取所有合约列表，然后查询每个合约的持仓
	contracts, _, err := t.client.FuturesApi.ListFuturesContracts(t.ctx, t.settle)
	if err != nil {
		return nil, fmt.Errorf("获取合约列表失败: %w", err)
	}

	var result []map[string]interface{}
	for _, contract := range contracts {
		// 查询该合约的持仓
		position, _, err := t.client.FuturesApi.GetPosition(t.ctx, t.settle, contract.Name)
		if err != nil {
			// 如果返回POSITION_NOT_FOUND错误，说明没有持仓，跳过
			if gateErr, ok := err.(gateapi.GateAPIError); ok {
				if gateErr.Label == "POSITION_NOT_FOUND" {
					continue
				}
			}
			// 其他错误记录但继续处理其他合约
			log.Printf("⚠ 获取合约 %s 持仓失败: %v", contract.Name, err)
			continue
		}

		// 持仓数量为0时跳过
		posSize := position.Size
		if posSize == 0 {
			continue
		}

		posMap := make(map[string]interface{})

		// Gate.io合约格式: BTC_USDT -> BTCUSDT
		symbol := convertGateContractToSymbol(contract.Name)
		posMap["symbol"] = symbol

		// 持仓数量和方向
		if posSize > 0 {
			posMap["side"] = "long"
			posMap["positionAmt"] = float64(posSize)
		} else {
			posMap["side"] = "short"
			posMap["positionAmt"] = float64(-posSize) // 转为正数
		}

		// 解析价格信息（都是string类型）
		entryPrice, _ := strconv.ParseFloat(position.EntryPrice, 64)
		markPrice, _ := strconv.ParseFloat(position.MarkPrice, 64)
		unrealizedPnl, _ := strconv.ParseFloat(position.UnrealisedPnl, 64)
		liquidationPrice, _ := strconv.ParseFloat(position.LiqPrice, 64)
		
		// 解析保证金（Gate.io API直接返回，优先使用）
		positionMargin, _ := strconv.ParseFloat(position.Margin, 64)

		// 解析杠杆
		leverage := 10.0 // 默认值
		if position.Leverage != "" {
			lev, err := strconv.ParseFloat(position.Leverage, 64)
			if err == nil {
				leverage = lev
			}
		}

		posMap["entryPrice"] = entryPrice
		posMap["markPrice"] = markPrice
		posMap["unRealizedProfit"] = unrealizedPnl
		posMap["leverage"] = leverage
		posMap["liquidationPrice"] = liquidationPrice
		posMap["margin"] = positionMargin // 添加API返回的保证金字段

		result = append(result, posMap)

		// 缓存合约信息（用于后续获取精度）
		t.contractCacheMutex.Lock()
		t.contractCache[contract.Name] = &contract
		t.contractCacheMutex.Unlock()
	}

	// 更新缓存
	t.positionsCacheMutex.Lock()
	t.cachedPositions = result
	t.positionsCacheTime = time.Now()
	t.positionsCacheMutex.Unlock()

	return result, nil
}

// SetLeverage 设置杠杆
func (t *GateTrader) SetLeverage(symbol string, leverage int) error {
	contract := convertSymbolToGateContract(symbol)
	leverageStr := strconv.Itoa(leverage)

	_, _, err := t.client.FuturesApi.UpdatePositionLeverage(t.ctx, t.settle, contract, leverageStr, nil)
	if err != nil {
		// 如果错误信息包含"No need to change"，说明杠杆已经是目标值
		if gateErr, ok := err.(gateapi.GateAPIError); ok {
			if strings.Contains(gateErr.Message, "No need to change") || strings.Contains(gateErr.Message, "already") {
				log.Printf("  ✓ %s 杠杆已是 %dx", symbol, leverage)
				return nil
			}
		}
		return fmt.Errorf("设置杠杆失败: %w", err)
	}

	log.Printf("  ✓ %s 杠杆已切换为 %dx", symbol, leverage)

	// 切换杠杆后等待3秒（避免冷却期错误）
	log.Printf("  ⏱ 等待3秒冷却期...")
	time.Sleep(3 * time.Second)

	return nil
}

// OpenLong 开多仓
func (t *GateTrader) OpenLong(symbol string, quantity float64, leverage int) (map[string]interface{}, error) {
	// 先取消该币种的所有委托单
	if err := t.CancelAllOrders(symbol); err != nil {
		log.Printf("  ⚠ 取消旧委托单失败（可能没有委托单）: %v", err)
	}

	// 设置杠杆
	if err := t.SetLeverage(symbol, leverage); err != nil {
		return nil, err
	}

	contract := convertSymbolToGateContract(symbol)

	// 格式化数量到正确精度
	quantityStr, err := t.FormatQuantity(symbol, quantity)
	if err != nil {
		return nil, err
	}

	// 转换为整数（Gate.io要求数量为整数）
	quantityInt, err := strconv.ParseInt(quantityStr, 10, 64)
	if err != nil {
		// 如果无法转换为整数，尝试四舍五入
		quantityInt = int64(quantity + 0.5)
	}

	// 创建市价买入订单（IOC类型，价格为0表示市价）
	order := gateapi.FuturesOrder{
		Contract: contract,
		Size:     quantityInt, // 正数表示买入（开多）
		Price:    "0",         // 0表示市价单
		Tif:      "ioc",       // Immediate or Cancel
	}

	orderResponse, _, err := t.client.FuturesApi.CreateFuturesOrder(t.ctx, t.settle, order)
	if err != nil {
		return nil, fmt.Errorf("开多仓失败: %w", err)
	}

	log.Printf("✓ 开多仓成功: %s 数量: %d", symbol, quantityInt)
	log.Printf("  订单ID: %d", orderResponse.Id)

	result := make(map[string]interface{})
	result["orderId"] = orderResponse.Id
	result["symbol"] = symbol
	result["status"] = orderResponse.Status
	return result, nil
}

// OpenShort 开空仓
func (t *GateTrader) OpenShort(symbol string, quantity float64, leverage int) (map[string]interface{}, error) {
	// 先取消该币种的所有委托单
	if err := t.CancelAllOrders(symbol); err != nil {
		log.Printf("  ⚠ 取消旧委托单失败（可能没有委托单）: %v", err)
	}

	// 设置杠杆
	if err := t.SetLeverage(symbol, leverage); err != nil {
		return nil, err
	}

	contract := convertSymbolToGateContract(symbol)

	// 格式化数量到正确精度
	quantityStr, err := t.FormatQuantity(symbol, quantity)
	if err != nil {
		return nil, err
	}

	// 转换为整数（Gate.io要求数量为整数）
	quantityInt, err := strconv.ParseInt(quantityStr, 10, 64)
	if err != nil {
		quantityInt = int64(quantity + 0.5)
	}

	// 创建市价卖出订单（负数表示卖出开空）
	order := gateapi.FuturesOrder{
		Contract: contract,
		Size:     -quantityInt, // 负数表示卖出（开空）
		Price:    "0",           // 0表示市价单
		Tif:      "ioc",         // Immediate or Cancel
	}

	orderResponse, _, err := t.client.FuturesApi.CreateFuturesOrder(t.ctx, t.settle, order)
	if err != nil {
		return nil, fmt.Errorf("开空仓失败: %w", err)
	}

	log.Printf("✓ 开空仓成功: %s 数量: %d", symbol, quantityInt)
	log.Printf("  订单ID: %d", orderResponse.Id)

	result := make(map[string]interface{})
	result["orderId"] = orderResponse.Id
	result["symbol"] = symbol
	result["status"] = orderResponse.Status
	return result, nil
}

// CloseLong 平多仓
func (t *GateTrader) CloseLong(symbol string, quantity float64) (map[string]interface{}, error) {
	// 如果数量为0，获取当前持仓数量
	if quantity == 0 {
		positions, err := t.GetPositions()
		if err != nil {
			return nil, err
		}

		for _, pos := range positions {
			if pos["symbol"] == symbol && pos["side"] == "long" {
				quantity = pos["positionAmt"].(float64)
				break
			}
		}

		if quantity == 0 {
			return nil, fmt.Errorf("没有找到 %s 的多仓", symbol)
		}
	}

	contract := convertSymbolToGateContract(symbol)

	// 格式化数量
	quantityStr, err := t.FormatQuantity(symbol, quantity)
	if err != nil {
		return nil, err
	}

	quantityInt, err := strconv.ParseInt(quantityStr, 10, 64)
	if err != nil {
		quantityInt = int64(quantity + 0.5)
	}

	// 创建市价卖出订单（平多）
	order := gateapi.FuturesOrder{
		Contract:   contract,
		Size:       -quantityInt, // 负数表示卖出（平多）
		Price:       "0",          // 市价单
		Tif:        "ioc",
		ReduceOnly: true, // 只平仓，不开新仓
	}

	orderResponse, _, err := t.client.FuturesApi.CreateFuturesOrder(t.ctx, t.settle, order)
	if err != nil {
		return nil, fmt.Errorf("平多仓失败: %w", err)
	}

	log.Printf("✓ 平多仓成功: %s 数量: %d", symbol, quantityInt)

	// 平仓后取消该币种的所有挂单
	if err := t.CancelAllOrders(symbol); err != nil {
		log.Printf("  ⚠ 取消挂单失败: %v", err)
	}

	result := make(map[string]interface{})
	result["orderId"] = orderResponse.Id
	result["symbol"] = symbol
	result["status"] = orderResponse.Status
	return result, nil
}

// CloseShort 平空仓
func (t *GateTrader) CloseShort(symbol string, quantity float64) (map[string]interface{}, error) {
	// 如果数量为0，获取当前持仓数量
	if quantity == 0 {
		positions, err := t.GetPositions()
		if err != nil {
			return nil, err
		}

		for _, pos := range positions {
			if pos["symbol"] == symbol && pos["side"] == "short" {
				quantity = pos["positionAmt"].(float64)
				break
			}
		}

		if quantity == 0 {
			return nil, fmt.Errorf("没有找到 %s 的空仓", symbol)
		}
	}

	contract := convertSymbolToGateContract(symbol)

	// 格式化数量
	quantityStr, err := t.FormatQuantity(symbol, quantity)
	if err != nil {
		return nil, err
	}

	quantityInt, err := strconv.ParseInt(quantityStr, 10, 64)
	if err != nil {
		quantityInt = int64(quantity + 0.5)
	}

	// 创建市价买入订单（平空）
	order := gateapi.FuturesOrder{
		Contract:   contract,
		Size:       quantityInt, // 正数表示买入（平空）
		Price:      "0",         // 市价单
		Tif:        "ioc",
		ReduceOnly: true, // 只平仓，不开新仓
	}

	orderResponse, _, err := t.client.FuturesApi.CreateFuturesOrder(t.ctx, t.settle, order)
	if err != nil {
		return nil, fmt.Errorf("平空仓失败: %w", err)
	}

	log.Printf("✓ 平空仓成功: %s 数量: %d", symbol, quantityInt)

	// 平仓后取消该币种的所有挂单
	if err := t.CancelAllOrders(symbol); err != nil {
		log.Printf("  ⚠ 取消挂单失败: %v", err)
	}

	result := make(map[string]interface{})
	result["orderId"] = orderResponse.Id
	result["symbol"] = symbol
	result["status"] = orderResponse.Status
	return result, nil
}

// CancelAllOrders 取消该币种的所有挂单
func (t *GateTrader) CancelAllOrders(symbol string) error {
	contract := convertSymbolToGateContract(symbol)

	_, _, err := t.client.FuturesApi.CancelFuturesOrders(t.ctx, t.settle, contract, nil)
	if err != nil {
		// 如果没有挂单，不算错误
		if gateErr, ok := err.(gateapi.GateAPIError); ok {
			if strings.Contains(gateErr.Message, "not found") || strings.Contains(gateErr.Message, "empty") {
				return nil
			}
		}
		return fmt.Errorf("取消挂单失败: %w", err)
	}

	log.Printf("  ✓ 已取消 %s 的所有挂单", symbol)
	return nil
}

// GetMarketPrice 获取市场价格
func (t *GateTrader) GetMarketPrice(symbol string) (float64, error) {
	contract := convertSymbolToGateContract(symbol)

	// 获取ticker信息
	tickers, _, err := t.client.FuturesApi.ListFuturesTickers(t.ctx, t.settle, &gateapi.ListFuturesTickersOpts{
		Contract: optional.NewString(contract),
	})
	if err != nil {
		return 0, fmt.Errorf("获取价格失败: %w", err)
	}

	if len(tickers) == 0 {
		return 0, fmt.Errorf("未找到 %s 的价格", symbol)
	}

	lastPrice, err := strconv.ParseFloat(tickers[0].Last, 64)
	if err != nil {
		return 0, fmt.Errorf("价格格式错误: %w", err)
	}

	return lastPrice, nil
}

// SetStopLoss 设置止损单
func (t *GateTrader) SetStopLoss(symbol string, positionSide string, quantity, stopPrice float64) error {
	contract := convertSymbolToGateContract(symbol)

	// 格式化数量
	quantityStr, err := t.FormatQuantity(symbol, quantity)
	if err != nil {
		return err
	}

	quantityInt, err := strconv.ParseInt(quantityStr, 10, 64)
	if err != nil {
		quantityInt = int64(quantity + 0.5)
	}

	// 格式化止损价格
	stopPriceStr := fmt.Sprintf("%.8f", stopPrice)

	// 判断方向
	var size int64
	var rule int32 // 触发规则：1表示>=触发，2表示<=触发
	if positionSide == "LONG" {
		size = -quantityInt // 多仓止损 = 卖出
		rule = 2            // 价格<=触发价时触发（多仓止损）
	} else {
		size = quantityInt // 空仓止损 = 买入
		rule = 1            // 价格>=触发价时触发（空仓止损）
	}

	// Gate.io使用价格触发订单来实现止损
	triggerOrder := gateapi.FuturesPriceTriggeredOrder{
		Initial: gateapi.FuturesInitialOrder{
			Contract:   contract,
			Size:       size,
			Price:      "0", // 市价单
			Tif:        "ioc",
			ReduceOnly: true,
		},
		Trigger: gateapi.FuturesPriceTrigger{
			StrategyType: 0,        // 0: 按价格触发
			PriceType:    1,        // 1: 标记价格
			Price:        stopPriceStr,
			Rule:         rule,     // 触发规则
			Expiration:   2592000,  // 30天过期
		},
	}

	_, _, err = t.client.FuturesApi.CreatePriceTriggeredOrder(t.ctx, t.settle, triggerOrder)
	if err != nil {
		return fmt.Errorf("设置止损失败: %w", err)
	}

	log.Printf("  止损价设置: %.4f", stopPrice)
	return nil
}

// SetTakeProfit 设置止盈单
func (t *GateTrader) SetTakeProfit(symbol string, positionSide string, quantity, takeProfitPrice float64) error {
	contract := convertSymbolToGateContract(symbol)

	// 格式化数量
	quantityStr, err := t.FormatQuantity(symbol, quantity)
	if err != nil {
		return err
	}

	quantityInt, err := strconv.ParseInt(quantityStr, 10, 64)
	if err != nil {
		quantityInt = int64(quantity + 0.5)
	}

	// 格式化止盈价格
	takeProfitPriceStr := fmt.Sprintf("%.8f", takeProfitPrice)

	// 判断方向
	var size int64
	var rule int32 // 触发规则：1表示>=触发，2表示<=触发
	if positionSide == "LONG" {
		size = -quantityInt // 多仓止盈 = 卖出
		rule = 1            // 价格>=触发价时触发（多仓止盈）
	} else {
		size = quantityInt // 空仓止盈 = 买入
		rule = 2            // 价格<=触发价时触发（空仓止盈）
	}

	// Gate.io使用价格触发订单来实现止盈
	triggerOrder := gateapi.FuturesPriceTriggeredOrder{
		Initial: gateapi.FuturesInitialOrder{
			Contract:   contract,
			Size:       size,
			Price:      "0", // 市价单
			Tif:        "ioc",
			ReduceOnly: true,
		},
		Trigger: gateapi.FuturesPriceTrigger{
			StrategyType: 0,        // 0: 按价格触发
			PriceType:    1,        // 1: 标记价格
			Price:        takeProfitPriceStr,
			Rule:         rule,     // 触发规则
			Expiration:   2592000,  // 30天过期
		},
	}

	_, _, err = t.client.FuturesApi.CreatePriceTriggeredOrder(t.ctx, t.settle, triggerOrder)
	if err != nil {
		return fmt.Errorf("设置止盈失败: %w", err)
	}

	log.Printf("  止盈价设置: %.4f", takeProfitPrice)
	return nil
}

// FormatQuantity 格式化数量到正确的精度
func (t *GateTrader) FormatQuantity(symbol string, quantity float64) (string, error) {
	contract := convertSymbolToGateContract(symbol)

	// 获取合约信息（带缓存）
	contractInfo, err := t.getContractInfo(contract)
	if err != nil {
		// 如果获取失败，使用默认精度
		log.Printf("  ⚠ 获取合约 %s 信息失败，使用默认精度: %v", contract, err)
		return fmt.Sprintf("%.0f", quantity), nil
	}

	// Gate.io使用OrderSizeMin
	// 数量必须不小于OrderSizeMin
	orderSizeMin := float64(contractInfo.OrderSizeMin)

	// 确保不小于最小数量
	if quantity < orderSizeMin {
		quantity = orderSizeMin
	}

	// Gate.io合约通常使用整数数量，所以直接四舍五入到整数
	quantity = math.Round(quantity)

	// 计算精度（Gate.io通常使用整数，所以精度为0）
	precision := 0

	format := fmt.Sprintf("%%.%df", precision)
	return fmt.Sprintf(format, quantity), nil
}

// getContractInfo 获取合约信息（带缓存）
func (t *GateTrader) getContractInfo(contract string) (*gateapi.Contract, error) {
	// 先检查缓存
	t.contractCacheMutex.RLock()
	if cached, ok := t.contractCache[contract]; ok {
		t.contractCacheMutex.RUnlock()
		return cached, nil
	}
	t.contractCacheMutex.RUnlock()

	// 缓存未命中，查询API
	contractInfo, _, err := t.client.FuturesApi.GetFuturesContract(t.ctx, t.settle, contract)
	if err != nil {
		return nil, err
	}

	// 更新缓存
	t.contractCacheMutex.Lock()
	t.contractCache[contract] = &contractInfo
	t.contractCacheMutex.Unlock()

	return &contractInfo, nil
}

// convertSymbolToGateContract 将标准symbol转换为Gate.io合约格式
// 例如: "BTCUSDT" -> "BTC_USDT"
func convertSymbolToGateContract(symbol string) string {
	symbol = strings.ToUpper(symbol)
	// 如果已经有下划线，直接返回
	if strings.Contains(symbol, "_") {
		return symbol
	}
	// 去掉USDT后缀，然后加上下划线
	if strings.HasSuffix(symbol, "USDT") {
		base := symbol[:len(symbol)-4]
		return base + "_USDT"
	}
	return symbol
}

// convertGateContractToSymbol 将Gate.io合约格式转换为标准symbol
// 例如: "BTC_USDT" -> "BTCUSDT"
func convertGateContractToSymbol(contract string) string {
	contract = strings.ToUpper(contract)
	// 替换下划线
	return strings.Replace(contract, "_", "", -1)
}

// calculatePrecisionFromStep 根据step计算精度
func calculatePrecisionFromStep(step float64) int {
	if step == 0 {
		return 0
	}
	stepStr := fmt.Sprintf("%.10f", step)
	stepStr = strings.TrimRight(stepStr, "0")
	if strings.Contains(stepStr, ".") {
		return len(stepStr) - strings.Index(stepStr, ".") - 1
	}
	return 0
}
