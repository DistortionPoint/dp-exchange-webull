# List Option Snapshots

Retrieves a real-time option snapshot (price, change, volume, best bid/ask). US options only.

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
  "path": "/market-data/options/snapshots/list",
  "method": "get",
  "tags": [
    "Options Market Data"
  ],
  "description": "Retrieves a real-time option snapshot (price, change, volume, best bid/ask). US options only.",
  "operationId": "optionSnapshot",
  "parameters": [
    {
      "name": "symbols",
      "in": "query",
      "description": "List of option symbols, separated by commas; maximum 20 symbols per query. Example: AAPL260522C00300000",
      "required": true,
      "schema": {
        "type": "string"
      },
      "example": "AAPL260522C00300000,TSLA251219C00450000"
    },
    {
      "name": "category",
      "in": "query",
      "description": "Security type. Currently only `US_OPTION` is supported for this interface.",
      "required": true,
      "schema": {
        "type": "string",
        "enum": [
          "US_OPTION"
        ]
      },
      "example": "US_OPTION"
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
                  "description": "Unique instrument identifier for this option contract in the Webull system or exchange.",
                  "example": "470059643"
                },
                "symbol": {
                  "type": "string",
                  "description": "Option contract symbol used in trading and market data, e.g. front-month code provided by the exchange.",
                  "example": "AAPL260522C00300000"
                },
                "price": {
                  "type": "string",
                  "description": "Last traded price (last done) of the option contract, quoted in the contract's trading currency (e.g. USD).",
                  "example": "47.35"
                },
                "open": {
                  "type": "string",
                  "description": "Session open price for this option contract. Represents the first traded price of the current regular trading session. If no trade has occurred in the session, this field may be empty.",
                  "example": "48.17"
                },
                "high": {
                  "type": "string",
                  "description": "Session high price for this option contract during the current regular trading session. If no trade has occurred in the session, this field may be empty.",
                  "example": "48.655"
                },
                "low": {
                  "type": "string",
                  "description": "Session low price for this option contract during the current regular trading session. If no trade has occurred in the session, this field may be empty.",
                  "example": "46.855"
                },
                "pre_close": {
                  "type": "string",
                  "description": "Previous settlement/close price of the option contract (typically the official settlement price of the previous trading day), quoted in the contract's trading currency.",
                  "example": "47.704"
                },
                "volume": {
                  "type": "string",
                  "description": "Accumulated traded volume for the current session, expressed in number of option contracts. If no trading occurred in the session, this field may be empty.",
                  "example": "48906"
                },
                "change": {
                  "type": "string",
                  "description": "Absolute price change of the last traded price relative to the previous settlement/close price. If no valid reference price or last trade exists, this field may be empty.",
                  "example": "-0.354"
                },
                "change_ratio": {
                  "type": "string",
                  "description": "Price change ratio of the last traded price relative to the previous settlement/close price, Expressed as a decimal (e.g., -0.0074 represents -0.74%)",
                  "example": "-0.0074"
                },
                "last_trade_time": {
                  "type": "integer",
                  "description": "Timestamp of the last executed trade for this option contract, expressed as Unix epoch time in milliseconds",
                  "format": "int64",
                  "example": 1761131406558
                },
                "close": {
                  "type": "string",
                  "description": "Close price of the option contract, quoted in the contract's trading currency.",
                  "example": "0.05"
                },
                "strike_price": {
                  "type": "string",
                  "description": "Strike price of the option contract, the price at which the option can be exercised.",
                  "example": "135.0"
                },
                "gamma": {
                  "type": "string",
                  "description": "Gamma, the rate of change of delta with respect to the underlying asset's price. Measures the convexity of the option's value.",
                  "example": "1.0E-4"
                },
                "delta": {
                  "type": "string",
                  "description": "Delta, the rate of change of the option price with respect to the underlying asset's price. Ranges from -1 to 1 for options.",
                  "example": "-0.0023"
                },
                "rho": {
                  "type": "string",
                  "description": "Rho, the rate of change of the option price with respect to the risk-free interest rate.",
                  "example": "-0.001"
                },
                "theta": {
                  "type": "string",
                  "description": "Theta, the rate of change of the option price with respect to time (time decay). Usually expressed as the change in option price per day.",
                  "example": "-0.0037"
                },
                "vega": {
                  "type": "string",
                  "description": "Vega, the rate of change of the option price with respect to volatility. Measures sensitivity to implied volatility changes.",
                  "example": "0.0077"
                },
                "imp_vol": {
                  "type": "string",
                  "description": "Implied volatility, the market's forecast of the underlying asset's likely movement. Expressed as a decimal (e.g., 0.609 represents 60.9%).",
                  "example": "0.609"
                },
                "open_interest": {
                  "type": "string",
                  "description": "Open interest, representing the total number of outstanding and unsettled option contracts for this instrument, expressed in number of contracts.",
                  "example": "14331"
                },
                "quote_time": {
                  "type": "integer",
                  "description": "Quote timestamp of this snapshot, expressed as Unix epoch time in milliseconds (UTC). Represents the time when this snapshot data was generated.",
                  "format": "int64",
                  "example": 1761131409276
                },
                "bid": {
                  "type": "string",
                  "description": "Best bid price (top of book), i.e. the highest price currently offered by buyers, quoted in the contract's trading currency.",
                  "example": "47.345"
                },
                "ask": {
                  "type": "string",
                  "description": "Best ask price (top of book), i.e. the lowest price currently offered by sellers, quoted in the contract's trading currency.",
                  "example": "47.355"
                },
                "ask_size": {
                  "type": "string",
                  "description": "Best ask size, i.e. the total quantity available at the best ask price, expressed in number of option contracts (whole contract units).",
                  "example": "2"
                },
                "bid_size": {
                  "type": "string",
                  "description": "Best bid size, i.e. the total quantity available at the best bid price, expressed in number of option contracts (whole contract units).",
                  "example": "1"
                },
                "deal_amount": {
                  "type": "string",
                  "description": "Total deal amount (traded value) for the option contract, quoted in the contract's trading currency.",
                  "example": "70267.5"
                }
              },
              "description": "Market snapshot data response object",
              "title": "OptionSnapshotVo"
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
    "name": "List Option Snapshots",
    "description": {
      "content": "Retrieves a real-time option snapshot (price, change, volume, best bid/ask). US options only.",
      "type": "text/plain"
    },
    "url": {
      "path": [
        "market-data",
        "options",
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
            "content": "(Required) List of option symbols, separated by commas; maximum 20 symbols per query. Example: AAPL260522C00300000",
            "type": "text/plain"
          },
          "key": "symbols",
          "value": ""
        },
        {
          "disabled": false,
          "description": {
            "content": "(Required) Security type. Currently only `US_OPTION` is supported for this interface.",
            "type": "text/plain"
          },
          "key": "category",
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
