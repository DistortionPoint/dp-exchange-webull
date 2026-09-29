# Get Order Detail

Retrieves order details, query the specified order details through the order ID or client_order_id.

# OpenAPI definition

```json
{
  "info": {
    "title": "Webull OpenAPI Documentation",
    "description": "The Webull OpenAPI enables integration of trading APIs, market data, and OAuth authentication for building trading applications and brokerage solutions. It supports HTTP-based historical and real-time market data and MQTT streaming via WebSocket/TCP, along with SDKs, secure authentication, and APIs for orders, accounts, and event contract trading.",
    "contact": {
      "name": "Webull Developer Support",
      "url": "https://www.webull.com/help",
      "email": "api-support@webull-us.com"
    },
    "version": "2.0",
    "x-logo": {
      "url": "static/png/logo.png"
    }
  },
  "servers": [
    {
      "url": "https://api.sandbox.webull.com"
    }
  ],
  "path": "/trading/orders/get",
  "method": "get",
  "tags": [
    "Order Query"
  ],
  "description": "Retrieves order details, query the specified order details through the order ID or client_order_id.",
  "operationId": "orderDetail",
  "parameters": [
    {
      "name": "account_id",
      "in": "query",
      "description": "Account identifier",
      "required": true,
      "schema": {
        "type": "String"
      },
      "example": "93IUJ28O9VO2KBGHDHR4H9"
    },
    {
      "name": "client_order_id",
      "in": "query",
      "description": "The last order ID returned from the previous response.<br/> Used for cursor-based pagination.<br/> Not required for the first page query.",
      "required": true,
      "schema": {
        "type": "String"
      },
      "example": "0KGOHL4PR2SLC0DKIND4TI0002"
    },
    {
      "name": "x-app-key",
      "in": "header",
      "description": "A unique identifier issued to a developer for accessing an application's API.",
      "required": true,
      "schema": {
        "type": "string"
      }
    },
    {
      "name": "x-app-secret",
      "in": "header",
      "description": "A unique key issued to developers to access the application's API.",
      "required": true,
      "schema": {
        "type": "string"
      }
    },
    {
      "name": "x-timestamp",
      "in": "header",
      "description": "Timestamp of the request, follows ISO8601 format: YYYY-MM-DDThh:mm:ssZ, e.g. 2023-07-16T19:23:51Z, only supports UTC time zone.",
      "required": true,
      "schema": {
        "type": "string"
      }
    },
    {
      "name": "x-signature-version",
      "in": "header",
      "description": "Signature algorithm version, default is 1.0.",
      "required": true,
      "schema": {
        "type": "string",
        "default": "1.0"
      },
      "examples": {
        "1.0": {
          "value": "1.0"
        }
      }
    },
    {
      "name": "x-signature-algorithm",
      "in": "header",
      "description": "Signature algorithm, default is HMAC-SHA1.",
      "required": true,
      "schema": {
        "type": "string",
        "default": "HMAC-SHA1"
      },
      "examples": {
        "HMAC-SHA1": {
          "value": "HMAC-SHA1"
        }
      }
    },
    {
      "name": "x-signature-nonce",
      "in": "header",
      "description": "Signature unique random number.",
      "required": true,
      "schema": {
        "type": "string"
      }
    },
    {
      "name": "x-access-token",
      "in": "header",
      "description": "An access token is a credential that represents the authorization granted to a client (e.g., a user or an application) to access specific protected resources on behalf of a user, without needing to share their password.",
      "required": true,
      "schema": {
        "type": "string"
      }
    },
    {
      "name": "x-version",
      "in": "header",
      "description": "API interface version. Supported values: `v2`, `v3`.",
      "required": true,
      "schema": {
        "type": "string",
        "default": "v3"
      },
      "examples": {
        "v3": {
          "value": "v3"
        }
      }
    },
    {
      "name": "x-signature",
      "in": "header",
      "description": "A signature is a unique digital fingerprint, typically encrypted, that verifies the authenticity and integrity of a message or transaction, ensuring it has not been tampered with during transmission.",
      "required": true,
      "schema": {
        "type": "string"
      }
    }
  ],
  "responses": {
    "200": {
      "description": "OK",
      "content": {
        "application/json": {
          "schema": {
            "required": [
              "combo_type",
              "orders"
            ],
            "type": "object",
            "properties": {
              "client_order_id": {
                "type": "string",
                "description": "Client-defined order identifier. Returned in the response for simple orders.<br/> Represents the unique order ID assigned by the user when placing the order.",
                "example": "THI82O5JB7MQ2K76LL5FSDS2CB"
              },
              "combo_order_id": {
                "type": "string",
                "description": "Combo Order ID",
                "example": "OBJOAD3OV65I6UDLO1N70GOO78"
              },
              "combo_type": {
                "type": "string",
                "description": "Type of order combination.<br/> Futures、Crypto、Event trading currently supports only the NORMAL combo type.<br/> &bull; NORMAL: Indicates a standard single order<br/> &bull; MASTER: Simple Order plus Take Profit Order or Stop Loss Order<br/> &bull; STOP_PROFIT: Take Profit Order<br/> &bull; STOP_LOSS: Stop Loss Order<br/> &bull; OTO: One Triggers Other Order<br/> &bull; OCO: One Cancels Other Order<br/> &bull; OTOCO: One Triggers a One Cancels Other Order<br/> Note: When placing take-profit/stop-loss orders to sell and close an existing position, submit only STOP_PROFIT/STOP_LOSS sub-orders (side = SELL) under the same client_combo_order_id; no MASTER order is required or supported in this scenario, since no new position is being opened.<br/> Note: For option orders, MASTER, STOP_PROFIT and STOP_LOSS combo types are only supported when option_strategy = SINGLE. Multi-leg option strategies (e.g. VERTICAL, STRADDLE, BUTTERFLY) only support the NORMAL combo type.<br/> Note: OTO, OCO and OTOCO combo types are only supported for stock (EQUITY) orders; option orders (including option_strategy = SINGLE) do not support OTO, OCO or OTOCO.<br/> Sub-order quantity limits by combo_type:\n\n| Scenario | combo_type | Supported order_type | Quantity | Description |\n|---|---|---|---|---|\n| Take-Profit/Stop-Loss | MASTER | MARKET, LIMIT | 1 | Master Order |\n| Take-Profit/Stop-Loss | STOP_PROFIT | LIMIT | 0-1 | Take Profit Order |\n| Take-Profit/Stop-Loss | STOP_LOSS | STOP_LOSS | 0-1 | Stop Loss Order |\n| OTO | MASTER | MARKET, LIMIT, STOP_LOSS, STOP_LOSS_LIMIT | 1 | Master Order |\n| OTO | OTO | MARKET, LIMIT, STOP_LOSS, STOP_LOSS_LIMIT | 1-6 | Triggered Order(s) |\n| OCO | OCO | LIMIT, STOP_LOSS, STOP_LOSS_LIMIT | 2-6 | Mutually Cancelling Orders |\n| OTOCO | MASTER | MARKET, LIMIT, STOP_LOSS, STOP_LOSS_LIMIT | 1 | Master Order |\n| OTOCO | OTOCO | LIMIT, STOP_LOSS, STOP_LOSS_LIMIT | 1-6 | OCO Order Set Triggered by MASTER |",
                "example": "NORMAL"
              },
              "orders": {
                "type": "array",
                "description": "Order Details",
                "items": {
                  "required": [
                    "client_order_id",
                    "entrust_type",
                    "order_id",
                    "order_type",
                    "place_time_at",
                    "side",
                    "status",
                    "symbol",
                    "time_in_force",
                    "total_quantity"
                  ],
                  "type": "object",
                  "properties": {
                    "client_order_id": {
                      "type": "string",
                      "description": "Client-defined order identifier. Returned in the response for simple orders.<br/> Represents the unique order ID assigned by the user when placing the order.",
                      "example": "THI82O5JB7MQ2K76LL5FSDS2CB"
                    },
                    "order_id": {
                      "type": "string",
                      "description": "System-generated order identifier. Returned in the response for simple orders.<br/> Represents the unique Webull order ID assigned by the system.",
                      "example": "0352U72LQI6DT0KF41GK000000"
                    },
                    "symbol": {
                      "type": "string",
                      "description": "Trading symbol of the financial instrument.Represents the unique identifier of the security in the specified market (e.g., ticker symbol for equities or option symbol code for derivatives).",
                      "example": "AAPL"
                    },
                    "side": {
                      "type": "string",
                      "description": "The order side indicating the intended trading direction of the transaction. <br/> The meaning of side may vary depending on the instrument_type and account type (e.g., margin vs. cash).<br/> Options trading Only BUY, SELL and SHORT are supported.<br/> Futures trading supports BUY and SELL sides only.<br/> Crypto trading supports BUY and SELL sides only.<br/> Algorithmic trading orders support BUY and SELL sides only.",
                      "example": "BUY",
                      "enum": [
                        "BUY",
                        "SELL",
                        "SHORT"
                      ]
                    },
                    "status": {
                      "type": "string",
                      "description": "&bull; PENDING: Indicates that the order has been submitted to the exchange and is awaiting completion<br/> &bull; SUBMITTED: Indicates that the order has been submitted to the exchange or webull<br/> &bull; CANCELLED: Indicates that the order has been successfully cancelled<br/> &bull; FILLED: Indicates that the order has been fully executed<br/> &bull; FAILED: Indicates a failed order, such as REJECTED<br/> &bull; PARTIAL_FILLED: Refers to the portion of the order that has been completed, but not all of it has been completed",
                      "example": "SUBMITTED",
                      "enum": [
                        "PENDING",
                        "SUBMITTED",
                        "CANCELLED",
                        "FILLED",
                        "FAILED",
                        "PARTIAL_FILLED"
                      ]
                    },
                    "order_type": {
                      "type": "string",
                      "description": "Specifies the type of order to be placed. Determines how the order will be executed in the market.<br/>Available order types depend on the market and instrument type.<br/>For crypto trading: <br/>&nbsp; &bull; Supported order types: MARKET, LIMIT, STOP_LOSS_LIMIT.<br/> &nbsp; &bull; When the order type is MARKET: time_in_force only supports IOC.<br/> &nbsp; &bull; When the order type is LIMIT or STOP_LOSS_LIMIT: time_in_force only supports DAY and GTC.<br/> &nbsp; &bull; When the order type is STOP_LOSS_LIMIT and the side is SELL: entrust_type only supports QTY.<br/> For stock, options and futures trading: <br/>&nbsp; &bull; <b>LIMIT:</b> Limit Order<br/>&nbsp; &bull; <b>MARKET:</b> Market Order<br/>&nbsp; &bull; <b>STOP_LOSS:</b> Stop Order<br/>&nbsp; &bull; <b>STOP_LOSS_LIMIT:</b> Stop Limit Order<br/>&nbsp; &bull; <b>TRAILING_STOP_LOSS:</b> Trailing Stop Order, Options not supported<br/>For event trading: <br/>&nbsp; &bull; Supported order types: LIMIT.<br/> The following order types are supported only for institutional stock orders.<br/>&nbsp; &bull; <b>MARKET_ON_OPEN:</b> Opening market order<br/> &nbsp; &bull; <b>MARKET_ON_CLOSE:</b> Closing market order<br/> &nbsp; &bull; <b>LIMIT_ON_OPEN:</b> Opening market limit order<br/>",
                      "example": "MARKET",
                      "enum": [
                        "MARKET",
                        "LIMIT",
                        "STOP_LOSS",
                        "STOP_LOSS_LIMIT",
                        "TRAILING_STOP_LOSS",
                        "MARKET_ON_OPEN",
                        "MARKET_ON_CLOSE",
                        "LIMIT_ON_OPEN"
                      ]
                    },
                    "instrument_type": {
                      "type": "string",
                      "description": "Type of financial instrument associated with the request.",
                      "example": "STOCK",
                      "enum": [
                        "EQUITY",
                        "OPTION",
                        "FUTURES",
                        "CRYPTO",
                        "EVENT"
                      ]
                    },
                    "support_trading_session": {
                      "type": "string",
                      "description": "Specifies the trading session for the order. Applicable to U.S. stock market orders only.<br/> Algorithmic trading order currently supports only regular trading hours.<br/> &bull; NIGHT: Only supports night trading.<br/> &bull; ALL: Include extended trading hours.<br/> &bull; CORE: Only support regular trading hours.",
                      "example": "CORE",
                      "enum": [
                        "ALL",
                        "CORE",
                        "NIGHT"
                      ]
                    },
                    "entrust_type": {
                      "type": "string",
                      "description": "Specifies the method for placing the order.<br/> Futures、Event trading currently supports only QTY entrust type.<br/> &bull; QTY: Order specified by quantity of shares or units.<br/> &bull; AMOUNT: Order specified by total cash amount. Supported for U.S. stock trading and Event Contract trading. When placing Event Contract orders using AMOUNT, only BUY orders are supported (side=BUY), and time_in_force must be FOK.",
                      "example": "QTY",
                      "enum": [
                        "QTY",
                        "AMOUNT"
                      ]
                    },
                    "time_in_force": {
                      "type": "string",
                      "description": "Specifies the duration for which the order remains active in the market (Time-In-Force).<br/> U.S. Stock, Futures, and Options trading support the following Time in Force (TIF) values: DAY and GTC.<br/> Crypto trading supports the following Time in Force (TIF) values: DAY, GTC, and IOC.<br/> Event trading supports the following Time in Force (TIF) values: DAY, GTC, IOC, GTD, and FOK.<br/> Algorithmic trading order supports the following Time in Force (TIF) values: DAY.<br/> &bull; DAY: The order is valid only for the current trading day and expires at the end of the day.<br/> &bull; GTC: Good-Till-Canceled, the order remains active until it is executed, explicitly canceled, or reaches the maximum allowed duration (typically 60 days).<br/> &bull; IOC: Immediate-Or-Cancel, the order attempts to execute immediately. Any portion that can be filled right away will be executed; any unfilled remainder is immediately cancelled.<br/> &bull; GTD: order that will automatically expire and be cancelled at a specific future date and time.<br/> &bull; FOK: Fill or Kill. The order must be filled in its entirety immediately; otherwise, the entire order will be canceled.",
                      "example": "DAY",
                      "enum": [
                        "DAY",
                        "GTC",
                        "IOC",
                        "GTD",
                        "FOK"
                      ]
                    },
                    "expire_date": {
                      "type": "string",
                      "description": "GTD order expire date. format (UTC). The value must be in yyyy-MM-dd format",
                      "example": "2026-12-01"
                    },
                    "total_quantity": {
                      "type": "string",
                      "description": "Total order quantity. Represents the total number of units submitted for this order.",
                      "example": "1"
                    },
                    "filled_quantity": {
                      "type": "string",
                      "description": "Quantity that has been executed. Represents the number of units that have been filled so far.",
                      "example": "1"
                    },
                    "filled_price": {
                      "type": "string",
                      "description": "Average transaction price of the filled quantity. If the order has not been executed yet, this may be zero or null.",
                      "example": "11.0"
                    },
                    "limit_price": {
                      "type": "string",
                      "description": "Limit Price",
                      "example": "11.0"
                    },
                    "stop_price": {
                      "type": "string",
                      "description": "Stop Price",
                      "example": "11.0"
                    },
                    "trailing_type": {
                      "type": "string",
                      "description": "When market continues to fall, the stop price to buy follows, or trails, the lowest price of a stock by a trail that you set. <br/> &bull; AMOUNT: By amount. <br/> &bull; PERCENTAGE: By percentage.",
                      "example": "AMOUNT"
                    },
                    "trailing_stop_step": {
                      "type": "string",
                      "description": "Trailing Stop Spread",
                      "example": "1"
                    },
                    "place_time": {
                      "type": "string",
                      "description": "Order placement time in milliseconds since Unix epoch.",
                      "example": "1726745361658",
                      "deprecated": true
                    },
                    "place_time_at": {
                      "type": "string",
                      "description": "Order placement time in ISO8601 format (UTC). Format: yyyy-MM-dd'T'HH:mm:ss.SSSZ",
                      "example": "2025-11-11T05:44:35.385Z"
                    },
                    "filled_time": {
                      "type": "string",
                      "description": "Time of the last executed trade in milliseconds since Unix epoch.",
                      "example": "1726745361871",
                      "deprecated": true
                    },
                    "filled_time_at": {
                      "type": "string",
                      "description": "Time of the last executed trade in ISO8601 format (UTC). Format: yyyy-MM-dd'T'HH:mm:ss.SSSZ",
                      "example": "2025-11-11T05:44:35.385Z"
                    },
                    "algo_type": {
                      "type": "string",
                      "description": "Algorithm strategy type.\n\nSupported values:\n- **TWAP**: Time Weighted Average Price. Buy/Sell at a time-weighted average price over a specific period.\n- **VWAP**: Volume Weighted Average Price. Buy/Sell at a volume-weighted average price over a specific period.\n- **POV**: Percentage of Volume. Buy/Sell using a percentage of volume algorithm to achieve a specific trading volume ratio.\n\nOnly market orders and limit orders are supported.",
                      "example": "TWAP",
                      "enum": [
                        "TWAP",
                        "VWAP",
                        "POV"
                      ]
                    },
                    "target_vol_percent": {
                      "type": "string",
                      "description": "The target participation percentage of the algorithmic order relative to the total expected market trading volume. This parameter limits the highest percentage of market volume that the POV algorithm is allowed to participate in at any time.  The value must be a positive integer between 1 and 20 (inclusive).",
                      "example": "10"
                    },
                    "max_target_percent": {
                      "type": "string",
                      "description": "The maximum participation rate of the algorithmic order relative to the total market traded volume. This parameter defines the intended execution aggressiveness for TWAP and VWAP strategies by specifying the proportion of market volume the algorithm aims to trade over the execution period. The value must be a positive integer between 1 and 20 (inclusive).",
                      "example": "10"
                    },
                    "algo_start_time": {
                      "type": "string",
                      "description": "The scheduled start time of the algorithmic order. Use US Eastern Time (ET). The algorithm will not begin execution before this time. The value must be in HH:mm:ss format (24-hour clock) and must be later than the current system time at the moment the order is submitted.",
                      "example": "09:30:00"
                    },
                    "algo_end_time": {
                      "type": "string",
                      "description": "The scheduled end time of the algorithmic order. Use US Eastern Time (ET). The value must be in HH:mm:ss format (24-hour clock).",
                      "example": "16:00:00"
                    },
                    "event_outcome": {
                      "type": "string",
                      "description": "Event outcome decision, only applicable to event orders.",
                      "example": "yes",
                      "enum": [
                        "yes",
                        "no"
                      ]
                    },
                    "event_trade_mode": {
                      "type": "string",
                      "description": "Specifies how the order quantity is expressed for event contract trading. Only applicable to event orders. When this field is set, the order executes at the best available market price; the limit_price field is ignored.<br/> &bull; TRADE_IN_AMOUNT: Specifies how the order quantity is expressed for event contract trading. When this field is set, the order executes at the best available market price.<br/> &bull; TRADE_IN_CONTRACT: The order is specified by the number of contracts the user wants to buy or sell at the best available market price. Requires quantity field.",
                      "example": "TRADE_IN_AMOUNT",
                      "enum": [
                        "TRADE_IN_AMOUNT",
                        "TRADE_IN_CONTRACT"
                      ]
                    },
                    "position_intent": {
                      "type": "string",
                      "description": "Represents the desired position strategy. Only supported for option orders. For combo orders, it can only be set on the MASTER order.<br/>Validation Rules:<br/>1. The position_intent must match the side parameter.<br/>2. Position existence check.<br/>3. The close intent must match the direction of the existing position.",
                      "example": "BUY_TO_OPEN",
                      "enum": [
                        "BUY_TO_OPEN",
                        "BUY_TO_CLOSE",
                        "SELL_TO_OPEN",
                        "SELL_TO_CLOSE"
                      ]
                    },
                    "leg_in_or_out": {
                      "type": "string",
                      "description": "Specifies whether this leg is being legged into or legged out of an existing position.<br/> Possible values:<br/> &bull; LEG_IN — Add this leg to an existing position.<br/> &bull; LEG_OUT — Close this leg from an existing multi-leg strategy position.",
                      "example": "LEG_IN",
                      "enum": [
                        "LEG_IN",
                        "LEG_OUT"
                      ]
                    },
                    "position_id": {
                      "type": "string",
                      "description": "The unique position identifier of the target leg to be legged in or legged out. Obtained from the Account Positions API. Required when leg_in_or_out is specified.",
                      "example": "FVIESMTK2IRC3FKKJSEE2U56SB"
                    },
                    "leg_in_strategy": {
                      "type": "string",
                      "description": "The target strategy type expected after legging in. Specifies what multi-leg strategy the position should become once this leg is added. Only applicable when leg_in_or_out is LEG_IN.<br/> Possible values:<br/> &bull; VERTICAL<br/> &bull; CALENDAR<br/> &bull; STRANGLE<br/> &bull; STRADDLE<br/> &bull; IRON_CONDOR<br/> &bull; BUTTERFLY<br/> &bull; COVERED_STOCK<br/> &bull; DIAGONAL",
                      "example": "VERTICAL",
                      "enum": [
                        "VERTICAL",
                        "CALENDAR",
                        "STRANGLE",
                        "STRADDLE",
                        "IRON_CONDOR",
                        "BUTTERFLY",
                        "COVERED_STOCK",
                        "DIAGONAL"
                      ]
                    },
                    "option_strategy": {
                      "type": "string",
                      "description": "Type of options strategy<br/> Possible values:<br/> &bull; SINGLE<br/> &bull; COVERED_STOCK<br/> &bull; STRADDLE<br/> &bull; STRANGLE<br/> &bull; VERTICAL<br/> &bull; CALENDAR<br/> &bull; BUTTERFLY<br/> &bull; CONDOR<br/> &bull; COLLAR_WITH_STOCK<br/> &bull; IRON_BUTTERFLY<br/> &bull; IRON_CONDOR<br/> &bull; DIAGONAL<br/> Note: When option_strategy is set to a multi-leg strategy (any value other than SINGLE), combo_type only supports NORMAL. The MASTER, STOP_PROFIT and STOP_LOSS combo types are only supported when option_strategy = SINGLE.<br/> Note: OTO, OCO and OTOCO combo types are only supported for stock (EQUITY) orders and are not supported for option orders regardless of option_strategy.",
                      "example": "SINGLE",
                      "enum": [
                        "SINGLE"
                      ]
                    },
                    "legs": {
                      "type": "array",
                      "description": "Leg detail",
                      "items": {
                        "required": [
                          "id",
                          "option_category",
                          "option_expire_date",
                          "option_type",
                          "quantity",
                          "side",
                          "strike_price",
                          "symbol"
                        ],
                        "type": "object",
                        "properties": {
                          "id": {
                            "type": "string",
                            "description": "Unique defined identifier for the leg.",
                            "example": "G2JAJPOR4KUA0F5I9LONH8J83A"
                          },
                          "symbol": {
                            "type": "string",
                            "description": "Trading symbol of the financial instrument.Represents the unique identifier of the security in the specified market (e.g., ticker symbol for equities or option symbol code for derivatives).",
                            "example": "AAPL"
                          },
                          "side": {
                            "type": "string",
                            "description": "The order side indicating the intended trading direction of the transaction. <br/> The meaning of side may vary depending on the instrument_type and account type (e.g., margin vs. cash).<br/> Options trading Only BUY, SELL and SHORT are supported.<br/> Futures trading supports BUY and SELL sides only.<br/> Crypto trading supports BUY and SELL sides only.<br/> Algorithmic trading orders support BUY and SELL sides only.",
                            "example": "BUY",
                            "enum": [
                              "BUY",
                              "SELL",
                              "SHORT"
                            ]
                          },
                          "quantity": {
                            "type": "string",
                            "description": "Quantity of the order. Specifies the number of shares or units to transact.<br/> For US stocks, fractional quantities are allowed and can include decimals.",
                            "example": "1"
                          },
                          "option_type": {
                            "type": "string",
                            "description": "Type of the option. <br/> &bull; CALL: Right to buy the underlying asset. <br/> &bull; PUT: Right to sell the underlying asset.",
                            "example": "CALL",
                            "enum": [
                              "CALL",
                              "PUT"
                            ]
                          },
                          "option_category": {
                            "type": "string",
                            "description": "Category of the option, indicating its exercise style.<br/> Possible values:<br/> &bull; AMERICAN: Can be exercised any time before expiration.<br/> &bull; EUROPEAN: Can only be exercised at expiration.",
                            "example": "AMERICAN",
                            "enum": [
                              "AMERICAN",
                              "EUROPEAN"
                            ]
                          },
                          "strike_price": {
                            "type": "string",
                            "description": "Exercise Price",
                            "example": "190.0"
                          },
                          "option_contract_multiplier": {
                            "type": "string",
                            "description": "The number of shares represented by one option contract.",
                            "example": "100"
                          },
                          "option_contract_deliverable": {
                            "type": "string",
                            "description": "The number of shares that must be delivered or received when exercising one option contract.",
                            "example": "100"
                          },
                          "option_expire_date": {
                            "type": "string",
                            "description": "Option Expiration date",
                            "example": "2025-11-21"
                          }
                        },
                        "description": "Leg detail",
                        "title": "OrderListLeg"
                      }
                    },
                    "commission": {
                      "type": "object",
                      "properties": {
                        "actual_commission": {
                          "type": "string",
                          "description": "Actual commission collected",
                          "example": "1.0"
                        },
                        "receivable_commission": {
                          "type": "string",
                          "description": "Receivable commission",
                          "example": "1.0"
                        }
                      },
                      "description": "Commission breakdown",
                      "title": "CommonCommissionResultVO"
                    },
                    "fees": {
                      "type": "array",
                      "description": "Fee breakdown",
                      "items": {
                        "type": "object",
                        "properties": {
                          "type": {
                            "type": "string",
                            "description": "Fee type",
                            "example": "FINRA_CAT_REGULATORY_FEE"
                          },
                          "actual_value": {
                            "type": "string",
                            "description": "Actual fee collected",
                            "example": "1.0"
                          },
                          "receivable_value": {
                            "type": "string",
                            "description": "Receivable fee",
                            "example": "1.0"
                          }
                        },
                        "description": "Fee breakdown",
                        "title": "CommonFeeResultVO"
                      }
                    }
                  },
                  "description": "Order Details",
                  "title": "OrderDetailItem"
                }
              }
            },
            "title": "OrderDetailResult"
          }
        }
      }
    },
    "401": {
      "description": "Unauthorized: Authentication required",
      "content": {
        "application/json": {
          "schema": {
            "type": "object",
            "properties": {
              "error_code": {
                "type": "string",
                "description": "Internal logic error code",
                "example": "UNAUTHORIZED"
              },
              "message": {
                "type": "string",
                "description": "Error message",
                "example": "Insufficient permission"
              }
            }
          }
        }
      }
    },
    "417": {
      "description": "A business logic error triggered when the request cannot be processed due to domain-specific constraints.",
      "content": {
        "application/json": {
          "schema": {
            "type": "object",
            "properties": {
              "error_code": {
                "type": "string",
                "description": "Internal logic error code",
                "example": "INVALID_PARAMETER"
              },
              "message": {
                "type": "string",
                "description": "Error message",
                "example": "Parameter error, phone"
              }
            }
          }
        }
      }
    },
    "500": {
      "description": "Internal Server Error.",
      "content": {
        "application/json": {
          "schema": {
            "type": "object",
            "properties": {
              "error_code": {
                "type": "string",
                "description": "Internal logic error code",
                "example": "SYSTEM_ERROR"
              },
              "message": {
                "type": "string",
                "description": "Error message",
                "example": "Internal Server Error"
              }
            }
          }
        }
      }
    }
  },
  "postman": {
    "name": "Get Order Detail",
    "description": {
      "content": "Retrieves order details, query the specified order details through the order ID or client_order_id.",
      "type": "text/plain"
    },
    "url": {
      "path": [
        "trading",
        "orders",
        "get"
      ],
      "host": [
        "{{baseUrl}}"
      ],
      "query": [
        {
          "disabled": false,
          "description": {
            "content": "(Required) Account identifier",
            "type": "text/plain"
          },
          "key": "account_id",
          "value": ""
        },
        {
          "disabled": false,
          "description": {
            "content": "(Required) The last order ID returned from the previous response.<br/> Used for cursor-based pagination.<br/> Not required for the first page query.",
            "type": "text/plain"
          },
          "key": "client_order_id",
          "value": ""
        }
      ],
      "variable": []
    },
    "header": [
      {
        "disabled": false,
        "description": {
          "content": "(Required) A unique identifier issued to a developer for accessing an application's API.",
          "type": "text/plain"
        },
        "key": "x-app-key",
        "value": ""
      },
      {
        "disabled": false,
        "description": {
          "content": "(Required) A unique key issued to developers to access the application's API.",
          "type": "text/plain"
        },
        "key": "x-app-secret",
        "value": ""
      },
      {
        "disabled": false,
        "description": {
          "content": "(Required) Timestamp of the request, follows ISO8601 format: YYYY-MM-DDThh:mm:ssZ, e.g. 2023-07-16T19:23:51Z, only supports UTC time zone.",
          "type": "text/plain"
        },
        "key": "x-timestamp",
        "value": ""
      },
      {
        "disabled": false,
        "description": {
          "content": "(Required) Signature algorithm version, default is 1.0.",
          "type": "text/plain"
        },
        "key": "x-signature-version",
        "value": ""
      },
      {
        "disabled": false,
        "description": {
          "content": "(Required) Signature algorithm, default is HMAC-SHA1.",
          "type": "text/plain"
        },
        "key": "x-signature-algorithm",
        "value": ""
      },
      {
        "disabled": false,
        "description": {
          "content": "(Required) Signature unique random number.",
          "type": "text/plain"
        },
        "key": "x-signature-nonce",
        "value": ""
      },
      {
        "disabled": false,
        "description": {
          "content": "(Required) An access token is a credential that represents the authorization granted to a client (e.g., a user or an application) to access specific protected resources on behalf of a user, without needing to share their password.",
          "type": "text/plain"
        },
        "key": "x-access-token",
        "value": ""
      },
      {
        "disabled": false,
        "description": {
          "content": "(Required) API interface version. Supported values: `v2`, `v3`.",
          "type": "text/plain"
        },
        "key": "x-version",
        "value": ""
      },
      {
        "disabled": false,
        "description": {
          "content": "(Required) A signature is a unique digital fingerprint, typically encrypted, that verifies the authenticity and integrity of a message or transaction, ensuring it has not been tampered with during transmission.",
          "type": "text/plain"
        },
        "key": "x-signature",
        "value": ""
      },
      {
        "key": "Accept",
        "value": "application/json"
      }
    ],
    "method": "GET"
  }
}
```
