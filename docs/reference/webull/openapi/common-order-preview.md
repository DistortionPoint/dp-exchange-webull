# Preview Order

Calculates the estimated amount and cost based on the incoming information, and support simple orders. For crypto trading, this feature is currently not supported.

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
  "path": "/trading/orders/preview",
  "method": "post",
  "tags": [
    "Trading"
  ],
  "description": "Calculates the estimated amount and cost based on the incoming information, and support simple orders. For crypto trading, this feature is currently not supported.",
  "operationId": "Common Order Preview",
  "parameters": [
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
  "requestBody": {
    "description": "Order Preview",
    "content": {
      "application/json": {
        "schema": {
          "type": "object",
          "properties": {
            "account_id": {
              "type": "string",
              "description": "Account identifier",
              "example": "93IUJ28O9VO2KBGHDHR4H9"
            },
            "client_combo_order_id": {
              "type": "string",
              "description": "Unique client-defined identifier for the combined order<br/> If combo_type = NORMAL and client_combo_order_id not need to set<br/> If combo_type != NORMAL and client_combo_order_id not provided<br/> the server will automatically generate one.<br/> To sell and close an existing position with take-profit/stop-loss, submit only STOP_PROFIT/STOP_LOSS sub-orders (side = SELL) grouped under the same client_combo_order_id; no MASTER order is required in this scenario.",
              "example": "0KGOHL4PR2SLC0DKIND4TI0001"
            },
            "new_orders": {
              "type": "array",
              "description": "Order Details",
              "items": {
                "required": [
                  "client_order_id",
                  "combo_type",
                  "entrust_type",
                  "instrument_type",
                  "market",
                  "order_type",
                  "side",
                  "symbol",
                  "time_in_force"
                ],
                "type": "object",
                "properties": {
                  "client_order_id": {
                    "type": "string",
                    "description": "Unique client-defined identifier for the order.<br/> Maximum length is 32 characters and must be unique per account.<br/> Used to track or reference the order when interacting with the system.",
                    "example": "0KGOHL4PR2SLC0DKIND4TI0002"
                  },
                  "combo_type": {
                    "type": "string",
                    "description": "Type of order combination.<br/> Futures、Event trading currently supports only the NORMAL combo type.<br/> &bull; NORMAL: Indicates a standard single order<br/> &bull; MASTER: Simple Order plus Take Profit Order or Stop Loss Order<br/> &bull; STOP_PROFIT: Take Profit Order<br/> &bull; STOP_LOSS: Stop Loss Order<br/> &bull; OTO: One Triggers Other Order<br/> &bull; OCO: One Cancels Other Order<br/> &bull; OTOCO: One Triggers a One Cancels Other Order<br/> Note: When placing take-profit/stop-loss orders to sell and close an existing position, submit only STOP_PROFIT/STOP_LOSS sub-orders (side = SELL) under the same client_combo_order_id; no MASTER order is required or supported in this scenario, since no new position is being opened.<br/> Note: For option orders, MASTER, STOP_PROFIT and STOP_LOSS combo types are only supported when option_strategy = SINGLE. Multi-leg option strategies (e.g. VERTICAL, STRADDLE, BUTTERFLY) only support the NORMAL combo type.<br/> Note: OTO, OCO and OTOCO combo types are only supported for stock (EQUITY) orders; option orders (including option_strategy = SINGLE) do not support OTO, OCO or OTOCO.",
                    "example": "NORMAL"
                  },
                  "option_strategy": {
                    "type": "string",
                    "description": "Type of options strategy<br/> Possible values:<br/> &bull; SINGLE<br/> &bull; COVERED_STOCK<br/> &bull; STRADDLE<br/> &bull; STRANGLE<br/> &bull; VERTICAL<br/> &bull; CALENDAR<br/> &bull; BUTTERFLY<br/> &bull; CONDOR<br/> &bull; COLLAR_WITH_STOCK<br/> &bull; IRON_BUTTERFLY<br/> &bull; IRON_CONDOR<br/> &bull; DIAGONAL<br/> Note: When option_strategy is set to a multi-leg strategy (any value other than SINGLE), combo_type only supports NORMAL. The MASTER, STOP_PROFIT and STOP_LOSS combo types are only supported when option_strategy = SINGLE.<br/> Note: OTO, OCO and OTOCO combo types are only supported for stock (EQUITY) orders and are not supported for option orders regardless of option_strategy.",
                    "example": "SINGLE",
                    "enum": [
                      "SINGLE"
                    ]
                  },
                  "instrument_type": {
                    "type": "string",
                    "description": "Type of financial instrument associated with the request.",
                    "example": "EQUITY",
                    "enum": [
                      "EQUITY",
                      "OPTION",
                      "FUTURES",
                      "EVENT"
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
                  "symbol": {
                    "type": "string",
                    "description": "Trading symbol of the financial instrument. Represents the unique identifier of the security in the specified market.",
                    "example": "AAPL"
                  },
                  "market": {
                    "type": "string",
                    "description": "Market code indicating the trading venue or regulatory region of the financial instrument. Used together with symbol and instrument_type to uniquely identify a tradable instrument.",
                    "example": "US",
                    "enum": [
                      "US"
                    ]
                  },
                  "side": {
                    "type": "string",
                    "description": "The order side indicating the intended trading direction of the transaction. <br/> The meaning of side may vary depending on the instrument_type and account type (e.g., margin vs. cash).<br/> Options trading Only BUY, SELL and SHORT are supported.<br/> Futures trading supports BUY and SELL sides only.<br/> Algorithmic trading orders support BUY and SELL sides only.",
                    "example": "BUY",
                    "enum": [
                      "BUY",
                      "SELL",
                      "SHORT"
                    ]
                  },
                  "order_type": {
                    "type": "string",
                    "description": "Specifies the type of order to be placed. Determines how the order will be executed in the market.<br/>Available order types depend on the market and instrument type.<br/>For stock, options and futures trading: <br/>&nbsp; &bull; <b>LIMIT:</b> Limit Order<br/>&nbsp; &bull; <b>MARKET:</b> Market Order<br/>&nbsp; &bull; <b>STOP_LOSS:</b> Stop Order<br/>&nbsp; &bull; <b>STOP_LOSS_LIMIT:</b> Stop Limit Order<br/>&nbsp; &bull; <b>TRAILING_STOP_LOSS:</b> Trailing Stop Order, Options not supported<br/>For event trading: <br/>&nbsp; &bull; Supported order types: LIMIT.<br/> The following order types are supported only for institutional stock orders.<br/>&nbsp; &bull; <b>MARKET_ON_OPEN:</b> Opening market order<br/> &nbsp; &bull; <b>MARKET_ON_CLOSE:</b> Closing market order<br/> &nbsp; &bull; <b>LIMIT_ON_OPEN:</b> Opening market limit order<br/>",
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
                  "time_in_force": {
                    "type": "string",
                    "description": "Specifies the duration for which the order remains active in the market (Time-In-Force).<br/> U.S. Stock, Futures, and Options trading support the following Time in Force (TIF) values: DAY and GTC.<br/> Event trading supports the following Time in Force (TIF) values: DAY, GTC, IOC, GTD, and FOK.<br/> Algorithmic trading order supports the following Time in Force (TIF) values: DAY.<br/> &bull; DAY: The order is valid only for the current trading day and expires at the end of the day.<br/> &bull; GTC: Good-Till-Canceled, the order remains active until it is executed, explicitly canceled, or reaches the maximum allowed duration (typically 60 days).<br/> &bull; IOC: Immediate-Or-Cancel, the order attempts to execute immediately. Any portion that can be filled right away will be executed; any unfilled remainder is immediately cancelled.<br/> &bull; GTD: order that will automatically expire and be cancelled at a specific future date and time.<br/> &bull; FOK: Fill or Kill. The order must be filled in its entirety immediately; otherwise, the entire order will be canceled.",
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
                  "stop_price": {
                    "type": "string",
                    "description": "Stop price of the order. Required when order_type is STOP_LOSS or STOP_LOSS_LIMIT.<br/> Specifies the trigger price at which the stop order becomes active.",
                    "example": "11.0"
                  },
                  "limit_price": {
                    "type": "string",
                    "description": "Limit price of the order. Required when order_type is LIMIT, STOP_LOSS_LIMIT.<br/> Specifies the maximum (for buy) or minimum (for sell) price at which the order can be executed.<br/> When event_trade_mode is set for an event contract trade, limit_price is not required.",
                    "example": "11.0"
                  },
                  "quantity": {
                    "type": "string",
                    "description": "Transaction quantity. You can specify decimals when placing fractional lot orders for US stocks.",
                    "example": "1"
                  },
                  "trailing_type": {
                    "type": "string",
                    "description": "When market continues to fall, the stop price to buy follows, or trails, the lowest price of a stock by a trail that you set. <br/> &bull; AMOUNT: By amount. <br/> &bull; PERCENTAGE: By percentage.",
                    "example": "AMOUNT"
                  },
                  "trailing_stop_step": {
                    "type": "string",
                    "description": "Trailing Stop Spread. If the tracking type is percentage, the tracking spread can not exceed 1,0.01 means 1%",
                    "example": "1"
                  },
                  "current_ask": {
                    "type": "string",
                    "description": "The current selling price seen by the user. Applicable to stock and option orders only.",
                    "example": "11.1"
                  },
                  "current_bid": {
                    "type": "string",
                    "description": "The current buying price seen by the user. Applicable to stock and option orders only.",
                    "example": "11.0"
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
                  "legs": {
                    "type": "array",
                    "description": "Option leg detail. Only required when previewing option orders.",
                    "items": {
                      "required": [
                        "instrument_type",
                        "market",
                        "side",
                        "symbol"
                      ],
                      "type": "object",
                      "properties": {
                        "side": {
                          "type": "string",
                          "description": "The order side indicating the intended trading direction of the transaction.",
                          "example": "BUY",
                          "enum": [
                            "BUY",
                            "SELL",
                            "SHORT"
                          ]
                        },
                        "quantity": {
                          "type": "string",
                          "description": "Quantity of the order or strategy leg. <br/>For stock legs, specifies the number of shares to transact <br/>For option legs, specifies the number of option contracts to transact for this leg and is expressed in whole contracts.",
                          "example": "1"
                        },
                        "market": {
                          "type": "string",
                          "description": "Market code indicating the trading venue or regulatory region of the financial instrument. Used together with symbol and instrument_type to uniquely identify a tradable instrument.",
                          "example": "US",
                          "enum": [
                            "US"
                          ]
                        },
                        "instrument_type": {
                          "type": "string",
                          "description": "Type of financial instrument associated with the request.",
                          "example": "OPTION",
                          "enum": [
                            "EQUITY",
                            "OPTION"
                          ]
                        },
                        "symbol": {
                          "type": "string",
                          "description": "Trading symbol of the financial instrument. Represents the unique identifier of the security in the specified market (e.g., ticker symbol for equities or option symbol code for derivatives).",
                          "example": "AAPL"
                        },
                        "strike_price": {
                          "type": "string",
                          "description": "Exercise price (strike price) of the option. <br/> Specifies the price at which the underlying asset can be bought (CALL) or sold (PUT) upon exercise.",
                          "example": "11.0"
                        },
                        "option_expire_date": {
                          "type": "string",
                          "description": "Expiration date. Format: yyyy-MM-dd",
                          "example": "2025-08-01"
                        },
                        "option_type": {
                          "type": "string",
                          "description": "Type of the option. <br/> &bull; CALL: Right to buy the underlying asset. <br/> &bull; PUT: Right to sell the underlying asset.",
                          "example": "CALL",
                          "enum": [
                            "CALL",
                            "PUT"
                          ]
                        }
                      },
                      "description": "Option leg detail. Only required when placing option orders.",
                      "title": "OptionCommonPlaceLegParam"
                    }
                  }
                },
                "description": "Order Details",
                "title": "OrderCommonPreviewItemParam"
              }
            }
          },
          "title": "OrderCommonPreviewParam"
        },
        "examples": {
          "Equity": {
            "summary": "Stock Limit Order",
            "description": "Equity",
            "value": {
              "account_id": "<your_account_id>",
              "new_orders": [
                {
                  "client_order_id": "<unique_id>",
                  "combo_type": "NORMAL",
                  "symbol": "AAPL",
                  "instrument_type": "EQUITY",
                  "market": "US",
                  "order_type": "LIMIT",
                  "limit_price": "180.00",
                  "quantity": "10",
                  "side": "BUY",
                  "time_in_force": "DAY",
                  "support_trading_session": "CORE",
                  "entrust_type": "QTY"
                }
              ]
            }
          },
          "Single Option": {
            "summary": "Single Leg Order",
            "description": "Single Option",
            "value": {
              "account_id": "<your_account_id>",
              "new_orders": [
                {
                  "client_order_id": "<unique_id>",
                  "combo_type": "NORMAL",
                  "order_type": "LIMIT",
                  "limit_price": "11.25",
                  "quantity": "1",
                  "option_strategy": "SINGLE",
                  "side": "BUY",
                  "time_in_force": "DAY",
                  "entrust_type": "QTY",
                  "instrument_type": "OPTION",
                  "market": "US",
                  "symbol": "AAPL",
                  "legs": [
                    {
                      "side": "BUY",
                      "quantity": "1",
                      "symbol": "AAPL",
                      "strike_price": "220.00",
                      "option_expire_date": "2026-06-19",
                      "instrument_type": "OPTION",
                      "option_type": "CALL",
                      "market": "US"
                    }
                  ]
                }
              ]
            }
          },
          "Multi Leg Options": {
            "summary": "Multi Leg Order",
            "description": "Multi Leg Options",
            "value": {
              "account_id": "<your_account_id>",
              "new_orders": [
                {
                  "client_order_id": "<unique_id>",
                  "combo_type": "NORMAL",
                  "side": "BUY",
                  "order_type": "LIMIT",
                  "quantity": "10",
                  "time_in_force": "DAY",
                  "entrust_type": "QTY",
                  "market": "US",
                  "instrument_type": "OPTION",
                  "symbol": "AAPL",
                  "option_strategy": "COVERED_STOCK",
                  "legs": [
                    {
                      "side": "BUY",
                      "quantity": "1000",
                      "market": "US",
                      "instrument_type": "EQUITY",
                      "symbol": "AAPL"
                    },
                    {
                      "side": "SELL",
                      "quantity": "10",
                      "market": "US",
                      "instrument_type": "OPTION",
                      "symbol": "AAPL",
                      "strike_price": "330",
                      "option_expire_date": "2026-11-20",
                      "option_type": "CALL"
                    }
                  ],
                  "limit_price": "28.8",
                  "position_intent": "BUY_TO_OPEN"
                }
              ]
            }
          },
          "Futures": {
            "summary": "Futures Order",
            "description": "Futures",
            "value": {
              "account_id": "<your_account_id>",
              "new_orders": [
                {
                  "combo_type": "NORMAL",
                  "client_order_id": "<unique_id>",
                  "symbol": "ESZ5",
                  "instrument_type": "FUTURES",
                  "market": "US",
                  "order_type": "LIMIT",
                  "limit_price": "4500",
                  "quantity": "1",
                  "side": "BUY",
                  "time_in_force": "DAY",
                  "entrust_type": "QTY"
                }
              ]
            }
          },
          "Event": {
            "summary": "Event Contract Order",
            "description": "Event",
            "value": {
              "account_id": "<your_account_id>",
              "new_orders": [
                {
                  "combo_type": "NORMAL",
                  "client_order_id": "<unique_id>",
                  "symbol": "KXRATECUTCOUNT-26DEC31-T3",
                  "instrument_type": "EVENT",
                  "market": "US",
                  "order_type": "LIMIT",
                  "limit_price": "0.10",
                  "quantity": "5",
                  "side": "BUY",
                  "time_in_force": "DAY",
                  "entrust_type": "QTY",
                  "event_outcome": "yes"
                }
              ]
            }
          },
          "Buy-to-Open TP/SL(Equity)": {
            "summary": "Open Position with Take-Profit and Stop-Loss (MASTER + STOP_PROFIT + STOP_LOSS)",
            "description": "Buy-to-Open TP/SL(Equity)",
            "value": {
              "account_id": "<your_account_id>",
              "client_combo_order_id": "<unique_combo_id>",
              "new_orders": [
                {
                  "client_order_id": "<unique_id_1>",
                  "combo_type": "MASTER",
                  "symbol": "AAPL",
                  "instrument_type": "EQUITY",
                  "market": "US",
                  "order_type": "LIMIT",
                  "quantity": "10",
                  "side": "BUY",
                  "time_in_force": "DAY",
                  "entrust_type": "QTY",
                  "support_trading_session": "CORE",
                  "limit_price": "309.53"
                },
                {
                  "client_order_id": "<unique_id_2>",
                  "combo_type": "STOP_PROFIT",
                  "symbol": "AAPL",
                  "instrument_type": "EQUITY",
                  "market": "US",
                  "order_type": "LIMIT",
                  "quantity": "10",
                  "side": "SELL",
                  "time_in_force": "DAY",
                  "entrust_type": "QTY",
                  "support_trading_session": "CORE",
                  "limit_price": "378.33"
                },
                {
                  "client_order_id": "<unique_id_3>",
                  "combo_type": "STOP_LOSS",
                  "symbol": "AAPL",
                  "instrument_type": "EQUITY",
                  "market": "US",
                  "order_type": "STOP_LOSS",
                  "quantity": "10",
                  "side": "SELL",
                  "time_in_force": "DAY",
                  "entrust_type": "QTY",
                  "support_trading_session": "CORE",
                  "stop_price": "292.34"
                }
              ]
            }
          },
          "Sell-to-Close TP/SL(Equity)": {
            "summary": "Sell to Close an Existing Position with Take-Profit and Stop-Loss (no MASTER order)",
            "description": "Sell-to-Close TP/SL(Equity)",
            "value": {
              "account_id": "<your_account_id>",
              "client_combo_order_id": "<unique_combo_id>",
              "new_orders": [
                {
                  "client_order_id": "<unique_id_1>",
                  "combo_type": "STOP_PROFIT",
                  "symbol": "TSLA",
                  "instrument_type": "EQUITY",
                  "market": "US",
                  "order_type": "LIMIT",
                  "quantity": "10",
                  "side": "SELL",
                  "time_in_force": "DAY",
                  "entrust_type": "QTY",
                  "support_trading_session": "CORE",
                  "limit_price": "326.59"
                },
                {
                  "client_order_id": "<unique_id_2>",
                  "combo_type": "STOP_LOSS",
                  "symbol": "TSLA",
                  "instrument_type": "EQUITY",
                  "market": "US",
                  "order_type": "STOP_LOSS",
                  "quantity": "10",
                  "side": "SELL",
                  "time_in_force": "DAY",
                  "entrust_type": "QTY",
                  "support_trading_session": "CORE",
                  "stop_price": "252.36"
                }
              ]
            }
          },
          "Buy-to-Open TP/SL(Single Option)": {
            "summary": "Open Position with Take-Profit and Stop-Loss (MASTER + STOP_PROFIT + STOP_LOSS)",
            "description": "Buy-to-Open TP/SL(Single Option)",
            "value": {
              "account_id": "<your_account_id>",
              "client_combo_order_id": "<unique_combo_id>",
              "new_orders": [
                {
                  "client_order_id": "<unique_id_1>",
                  "combo_type": "MASTER",
                  "symbol": "AAPL",
                  "instrument_type": "OPTION",
                  "market": "US",
                  "order_type": "LIMIT",
                  "quantity": "10",
                  "side": "BUY",
                  "time_in_force": "DAY",
                  "entrust_type": "QTY",
                  "option_strategy": "SINGLE",
                  "position_intent": "BUY_TO_OPEN",
                  "legs": [
                    {
                      "side": "BUY",
                      "quantity": "10",
                      "market": "US",
                      "instrument_type": "OPTION",
                      "symbol": "AAPL",
                      "strike_price": "330",
                      "option_expire_date": "2026-11-20",
                      "option_type": "CALL"
                    }
                  ],
                  "limit_price": "28.8"
                },
                {
                  "client_order_id": "<unique_id_2>",
                  "combo_type": "STOP_PROFIT",
                  "symbol": "AAPL",
                  "instrument_type": "OPTION",
                  "market": "US",
                  "order_type": "LIMIT",
                  "quantity": "10",
                  "side": "SELL",
                  "time_in_force": "GTC",
                  "entrust_type": "QTY",
                  "option_strategy": "SINGLE",
                  "position_intent": "SELL_TO_CLOSE",
                  "legs": [
                    {
                      "side": "SELL",
                      "quantity": "10",
                      "market": "US",
                      "instrument_type": "OPTION",
                      "symbol": "AAPL",
                      "strike_price": "330",
                      "option_expire_date": "2026-11-20",
                      "option_type": "CALL"
                    }
                  ],
                  "limit_price": "35.2"
                },
                {
                  "client_order_id": "<unique_id_3>",
                  "combo_type": "STOP_LOSS",
                  "symbol": "AAPL",
                  "instrument_type": "OPTION",
                  "market": "US",
                  "order_type": "STOP_LOSS",
                  "quantity": "10",
                  "side": "SELL",
                  "time_in_force": "GTC",
                  "entrust_type": "QTY",
                  "option_strategy": "SINGLE",
                  "position_intent": "SELL_TO_CLOSE",
                  "legs": [
                    {
                      "side": "SELL",
                      "quantity": "10",
                      "market": "US",
                      "instrument_type": "OPTION",
                      "symbol": "AAPL",
                      "strike_price": "330",
                      "option_expire_date": "2026-11-20",
                      "option_type": "CALL"
                    }
                  ],
                  "stop_price": "27.2"
                }
              ]
            }
          },
          "Sell-to-Close TP/SL(Single Option)": {
            "summary": "Sell to Close an Existing Position with Take-Profit and Stop-Loss (no MASTER order)",
            "description": "Sell-to-Close TP/SL(Single Option)",
            "value": {
              "account_id": "<your_account_id>",
              "client_combo_order_id": "<unique_combo_id>",
              "new_orders": [
                {
                  "client_order_id": "<unique_id_1>",
                  "combo_type": "STOP_PROFIT",
                  "symbol": "AAPL",
                  "instrument_type": "OPTION",
                  "market": "US",
                  "order_type": "LIMIT",
                  "quantity": "10",
                  "side": "SELL",
                  "time_in_force": "GTC",
                  "entrust_type": "QTY",
                  "option_strategy": "SINGLE",
                  "position_intent": "SELL_TO_CLOSE",
                  "legs": [
                    {
                      "side": "SELL",
                      "quantity": "10",
                      "market": "US",
                      "instrument_type": "OPTION",
                      "symbol": "AAPL",
                      "strike_price": "330",
                      "option_expire_date": "2026-11-20",
                      "option_type": "PUT"
                    }
                  ],
                  "limit_price": "16.6"
                },
                {
                  "client_order_id": "<unique_id_2>",
                  "combo_type": "STOP_LOSS",
                  "symbol": "AAPL",
                  "instrument_type": "OPTION",
                  "market": "US",
                  "order_type": "STOP_LOSS",
                  "quantity": "10",
                  "side": "SELL",
                  "time_in_force": "GTC",
                  "entrust_type": "QTY",
                  "option_strategy": "SINGLE",
                  "position_intent": "SELL_TO_CLOSE",
                  "legs": [
                    {
                      "side": "SELL",
                      "quantity": "10",
                      "market": "US",
                      "instrument_type": "OPTION",
                      "symbol": "AAPL",
                      "strike_price": "330",
                      "option_expire_date": "2026-11-20",
                      "option_type": "PUT"
                    }
                  ],
                  "stop_price": "12.7"
                }
              ]
            }
          },
          "OTO": {
            "summary": "One-Triggers-the-Other: Master Order Triggers a Single Follow-up Order",
            "description": "OTO",
            "value": {
              "account_id": "<your_account_id>",
              "client_combo_order_id": "<unique_combo_id>",
              "new_orders": [
                {
                  "client_order_id": "<unique_id_1>",
                  "combo_type": "MASTER",
                  "symbol": "AAPL",
                  "instrument_type": "EQUITY",
                  "market": "US",
                  "order_type": "LIMIT",
                  "limit_price": "180.00",
                  "quantity": "10",
                  "side": "BUY",
                  "time_in_force": "DAY",
                  "support_trading_session": "CORE",
                  "entrust_type": "QTY"
                },
                {
                  "client_order_id": "<unique_id_2>",
                  "combo_type": "OTO",
                  "symbol": "AAPL",
                  "instrument_type": "EQUITY",
                  "market": "US",
                  "order_type": "LIMIT",
                  "limit_price": "200.00",
                  "quantity": "10",
                  "side": "SELL",
                  "time_in_force": "DAY",
                  "entrust_type": "QTY",
                  "support_trading_session": "CORE"
                }
              ]
            }
          },
          "OCO": {
            "summary": "One-Cancels-the-Other: Two Sub-orders on an Existing Position, Filling One Cancels the Other",
            "description": "OCO",
            "value": {
              "account_id": "<your_account_id>",
              "client_combo_order_id": "<unique_combo_id>",
              "new_orders": [
                {
                  "market": "US",
                  "instrument_type": "EQUITY",
                  "symbol": "AAPL",
                  "time_in_force": "DAY",
                  "entrust_type": "QTY",
                  "support_trading_session": "CORE",
                  "combo_type": "OCO",
                  "order_type": "LIMIT",
                  "side": "BUY",
                  "quantity": "1",
                  "limit_price": "360.00",
                  "client_order_id": "<unique_id_1>"
                },
                {
                  "market": "US",
                  "instrument_type": "EQUITY",
                  "symbol": "AAPL",
                  "time_in_force": "DAY",
                  "entrust_type": "QTY",
                  "support_trading_session": "CORE",
                  "combo_type": "OCO",
                  "order_type": "LIMIT",
                  "side": "BUY",
                  "quantity": "1",
                  "limit_price": "370.80",
                  "client_order_id": "<unique_id_2>"
                }
              ]
            }
          },
          "OTOCO": {
            "summary": "One-Triggers-a-One-Cancels-the-Other: Master Order Triggers an OCO Order Set",
            "description": "OTOCO",
            "value": {
              "account_id": "<your_account_id>",
              "client_combo_order_id": "<unique_combo_id>",
              "new_orders": [
                {
                  "client_order_id": "<unique_id_1>",
                  "combo_type": "MASTER",
                  "symbol": "AAPL",
                  "instrument_type": "EQUITY",
                  "market": "US",
                  "order_type": "LIMIT",
                  "limit_price": "180.00",
                  "quantity": "10",
                  "side": "BUY",
                  "time_in_force": "DAY",
                  "support_trading_session": "CORE",
                  "entrust_type": "QTY"
                },
                {
                  "client_order_id": "<unique_id_2>",
                  "combo_type": "OTOCO",
                  "symbol": "AAPL",
                  "instrument_type": "EQUITY",
                  "market": "US",
                  "order_type": "LIMIT",
                  "limit_price": "200.00",
                  "quantity": "10",
                  "side": "SELL",
                  "time_in_force": "DAY",
                  "entrust_type": "QTY",
                  "support_trading_session": "CORE"
                },
                {
                  "client_order_id": "<unique_id_3>",
                  "combo_type": "OTOCO",
                  "symbol": "AAPL",
                  "instrument_type": "EQUITY",
                  "market": "US",
                  "order_type": "STOP_LOSS",
                  "stop_price": "170.00",
                  "quantity": "10",
                  "side": "SELL",
                  "time_in_force": "DAY",
                  "entrust_type": "QTY",
                  "support_trading_session": "CORE"
                }
              ]
            }
          }
        }
      }
    },
    "required": true
  },
  "responses": {
    "200": {
      "description": "OK",
      "content": {
        "application/json": {
          "schema": {
            "required": [
              "estimated_cost",
              "estimated_transaction_fee"
            ],
            "type": "object",
            "properties": {
              "estimated_cost": {
                "type": "string",
                "description": "Estimated capital required for the order. The meaning varies by product type:<br/>- Stocks / Options: estimated total consideration for the order, including option premium and other applicable charges,expressed in the account settlement currency.<br/>- Futures: estimated used margin (initial margin required to open/hold the position),expressed in the account settlement currency.<br/>The final capital usage may differ depending on the actual execution and fee settlement.",
                "example": "100"
              },
              "estimated_transaction_fee": {
                "type": "string",
                "description": "Estimated transaction fee for placing the order, including exchange, clearing, and commission fees. <br/> The actual fee may differ based on final execution.",
                "example": "1"
              }
            },
            "title": "OrderCommonPreviewResult"
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
      "content": {
        "application/json": {
          "schema": {
            "type": "object",
            "properties": {
              "error_code": {
                "type": "string",
                "description": "error code",
                "example": "OPENAPI_NO_NIGHT_TRADING_TIME"
              },
              "message": {
                "type": "string",
                "description": "error message",
                "example": "The current period does not support placing night orders"
              }
            },
            "description": "Business Response",
            "title": "BizResponse"
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
  "jsonRequestBodyExample": {
    "account_id": "93IUJ28O9VO2KBGHDHR4H9",
    "client_combo_order_id": "0KGOHL4PR2SLC0DKIND4TI0001",
    "new_orders": [
      {
        "client_order_id": "0KGOHL4PR2SLC0DKIND4TI0002",
        "combo_type": "NORMAL",
        "option_strategy": "SINGLE",
        "instrument_type": "EQUITY",
        "entrust_type": "QTY",
        "support_trading_session": "CORE",
        "symbol": "AAPL",
        "market": "US",
        "side": "BUY",
        "order_type": "MARKET",
        "time_in_force": "DAY",
        "expire_date": "2026-12-01",
        "stop_price": "11.0",
        "limit_price": "11.0",
        "quantity": "1",
        "trailing_type": "AMOUNT",
        "trailing_stop_step": "1",
        "current_ask": "11.1",
        "current_bid": "11.0",
        "algo_type": "TWAP",
        "target_vol_percent": "10",
        "max_target_percent": "10",
        "algo_start_time": "09:30:00",
        "algo_end_time": "16:00:00",
        "event_outcome": "yes",
        "event_trade_mode": "TRADE_IN_AMOUNT",
        "legs": [
          {
            "side": "BUY",
            "quantity": "1",
            "market": "US",
            "instrument_type": "OPTION",
            "symbol": "AAPL",
            "strike_price": "11.0",
            "option_expire_date": "2025-08-01",
            "option_type": "CALL"
          }
        ]
      }
    ]
  },
  "postman": {
    "name": "Preview Order",
    "description": {
      "content": "Calculates the estimated amount and cost based on the incoming information, and support simple orders. For crypto trading, this feature is currently not supported.",
      "type": "text/plain"
    },
    "url": {
      "path": [
        "trading",
        "orders",
        "preview"
      ],
      "host": [
        "{{baseUrl}}"
      ],
      "query": [],
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
        "key": "Content-Type",
        "value": "application/json"
      },
      {
        "key": "Accept",
        "value": "application/json"
      }
    ],
    "method": "POST",
    "body": {
      "mode": "raw",
      "raw": "",
      "options": {
        "raw": {
          "language": "json"
        }
      }
    }
  }
}
```
