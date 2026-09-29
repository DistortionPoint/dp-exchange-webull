# List Stock Snapshots

Retrieves a real-time stock snapshot (latest price, change, volume, turnover) with optional pre-market, after-hours and overnight data.

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
  "path": "/market-data/stocks/snapshots/list",
  "method": "get",
  "tags": [
    "Stocks Market Data"
  ],
  "description": "Retrieves a real-time stock snapshot (latest price, change, volume, turnover) with optional pre-market, after-hours and overnight data.",
  "operationId": "snapshot",
  "parameters": [
    {
      "name": "symbols",
      "in": "query",
      "description": "List of security symbols, supports JSON array format, multiple symbols separated by commas; maximum 100 symbols per query.",
      "required": true,
      "schema": {
        "type": "string"
      },
      "example": "AAPL"
    },
    {
      "name": "category",
      "in": "query",
      "description": "Security type. Category values are as shown in the enum; US_OPTION type query is currently not supported.",
      "required": true,
      "schema": {
        "type": "string",
        "enum": [
          "US_STOCK",
          "US_ETF"
        ]
      },
      "example": "US_STOCK"
    },
    {
      "name": "extend_hour_required",
      "in": "query",
      "description": "Whether to include pre-market and after-hours trading data.",
      "required": false,
      "schema": {
        "type": "string",
        "default": "false"
      },
      "example": false
    },
    {
      "name": "overnight_required",
      "in": "query",
      "description": "Whether to include overnight trading data.",
      "required": false,
      "schema": {
        "type": "string",
        "default": "false"
      },
      "example": false
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
            "type": "array",
            "items": {
              "required": [
                "symbol"
              ],
              "type": "object",
              "properties": {
                "instrument_id": {
                  "type": "string",
                  "description": "Instrument ID",
                  "example": "913256135"
                },
                "pre_close": {
                  "type": "string",
                  "description": "Previous close price",
                  "example": "101"
                },
                "change_ratio": {
                  "type": "string",
                  "description": "Change ratio",
                  "example": "0.05"
                },
                "symbol": {
                  "type": "string",
                  "description": "Security symbol",
                  "example": "AAPL"
                },
                "last_trade_time": {
                  "type": "integer",
                  "description": "Last trade time",
                  "format": "int64",
                  "example": 1640688000000
                },
                "price": {
                  "type": "string",
                  "description": "Current price",
                  "example": "100"
                },
                "open": {
                  "type": "string",
                  "description": "Open price, for US stocks it's intraday open price, excluding pre/post market data. No return value if no trading occurred on the day",
                  "example": "100"
                },
                "close": {
                  "type": "string",
                  "description": "Intraday close price",
                  "example": "101"
                },
                "high": {
                  "type": "string",
                  "description": "Today's high price, for US stocks it's intraday high, excluding pre/post market data. No return value if no trading occurred on the day",
                  "example": "105"
                },
                "low": {
                  "type": "string",
                  "description": "Today's low price, for US stocks it's intraday low, excluding pre/post market data. No return value if no trading occurred on the day",
                  "example": "99"
                },
                "volume": {
                  "type": "string",
                  "description": "Volume. No return value if no trading occurred on the day",
                  "example": "1000"
                },
                "change": {
                  "type": "string",
                  "description": "Change amount. No return value if no trading occurred on the day",
                  "example": "1.0"
                },
                "ask": {
                  "type": "string",
                  "description": "Ask",
                  "example": "13.9"
                },
                "ask_size": {
                  "type": "string",
                  "description": "Ask size (Quantity)",
                  "example": "5"
                },
                "bid": {
                  "type": "string",
                  "description": "Bid",
                  "example": "13.9"
                },
                "bid_size": {
                  "type": "string",
                  "description": "Bid size (Quantity)",
                  "example": "5"
                },
                "turnover": {
                  "type": "string",
                  "description": "Turnover rate.",
                  "example": "0.01"
                },
                "eps": {
                  "type": "string",
                  "description": "Earnings Per Share.",
                  "example": "7.465"
                },
                "eps_ttm": {
                  "type": "string",
                  "description": "Earnings Per Share (TTM).",
                  "example": "7.465"
                },
                "lot_size": {
                  "type": "string",
                  "description": "Shares per lot.",
                  "example": "1"
                },
                "bps": {
                  "type": "string",
                  "description": "Book Value Per Share.",
                  "example": "4.991"
                },
                "extend_hour_last_price": {
                  "type": "string",
                  "description": "Pre/post market latest price",
                  "example": "100.5"
                },
                "extend_hour_high": {
                  "type": "string",
                  "description": "Pre/post market high price",
                  "example": "101.0"
                },
                "extend_hour_low": {
                  "type": "string",
                  "description": "Pre/post market low price",
                  "example": "99.5"
                },
                "extend_hour_change": {
                  "type": "string",
                  "description": "Pre/post market change amount",
                  "example": "0.5"
                },
                "extend_hour_change_ratio": {
                  "type": "string",
                  "description": "Pre/post market change ratio",
                  "example": "0.005"
                },
                "extend_hour_volume": {
                  "type": "string",
                  "description": "Pre/post market volume",
                  "example": "200"
                },
                "extend_hour_last_trade_time": {
                  "type": "integer",
                  "description": "Current pre/post market trade time",
                  "format": "int64",
                  "example": 1640688000000
                },
                "ovn_price": {
                  "type": "string",
                  "description": "Overnight price",
                  "example": "100.25"
                },
                "ovn_high": {
                  "type": "string",
                  "description": "Overnight high price",
                  "example": "101.0"
                },
                "ovn_low": {
                  "type": "string",
                  "description": "Overnight low price",
                  "example": "99.5"
                },
                "ovn_volume": {
                  "type": "string",
                  "description": "Overnight volume",
                  "example": "500"
                },
                "ovn_change": {
                  "type": "string",
                  "description": "Overnight change amount",
                  "example": "0.25"
                },
                "ovn_change_ratio": {
                  "type": "string",
                  "description": "Overnight change ratio",
                  "example": "0.0025"
                },
                "ovn_last_trade_time": {
                  "type": "integer",
                  "description": "Overnight trade time",
                  "format": "int64",
                  "example": 1640688000000
                },
                "ovn_ask": {
                  "type": "string",
                  "description": "Overnight ask",
                  "example": "13.9"
                },
                "ovn_ask_size": {
                  "type": "string",
                  "description": "Overnight ask size (Quantity)",
                  "example": "5"
                },
                "ovn_bid": {
                  "type": "string",
                  "description": "Overnight bid",
                  "example": "13.9"
                },
                "ovn_bid_size": {
                  "type": "string",
                  "description": "Overnight bid size (Quantity)",
                  "example": "5"
                }
              },
              "description": "Market snapshot data response object",
              "title": "SnapshotVo"
            }
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
    "name": "List Stock Snapshots",
    "description": {
      "content": "Retrieves a real-time stock snapshot (latest price, change, volume, turnover) with optional pre-market, after-hours and overnight data.",
      "type": "text/plain"
    },
    "url": {
      "path": [
        "market-data",
        "stocks",
        "snapshots",
        "list"
      ],
      "host": [
        "{{baseUrl}}"
      ],
      "query": [
        {
          "disabled": false,
          "description": {
            "content": "(Required) List of security symbols, supports JSON array format, multiple symbols separated by commas; maximum 100 symbols per query.",
            "type": "text/plain"
          },
          "key": "symbols",
          "value": ""
        },
        {
          "disabled": false,
          "description": {
            "content": "(Required) Security type. Category values are as shown in the enum; US_OPTION type query is currently not supported.",
            "type": "text/plain"
          },
          "key": "category",
          "value": ""
        },
        {
          "disabled": false,
          "description": {
            "content": "Whether to include pre-market and after-hours trading data.",
            "type": "text/plain"
          },
          "key": "extend_hour_required",
          "value": ""
        },
        {
          "disabled": false,
          "description": {
            "content": "Whether to include overnight trading data.",
            "type": "text/plain"
          },
          "key": "overnight_required",
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
