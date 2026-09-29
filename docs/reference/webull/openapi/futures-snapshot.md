# List Futures Snapshots

Retrieves a real-time futures snapshot (latest price, change, volume).

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
  "path": "/market-data/futures/snapshots/list",
  "method": "get",
  "tags": [
    "Futures Market Data"
  ],
  "description": "Retrieves a real-time futures snapshot (latest price, change, volume).",
  "operationId": "futuresSnapshot",
  "parameters": [
    {
      "name": "symbols",
      "in": "query",
      "description": "List of futures symbols, separated by commas; maximum 20 symbols per query. Example: SILZ5,6BM6.",
      "required": true,
      "schema": {
        "type": "string"
      },
      "example": "SILZ5,6BM6"
    },
    {
      "name": "category",
      "in": "query",
      "description": "Security type. Currently only `US_FUTURES` is supported for this interface.",
      "required": true,
      "schema": {
        "type": "string",
        "enum": [
          "US_FUTURES"
        ]
      },
      "example": "US_FUTURES"
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
                "symbol": {
                  "type": "string",
                  "description": "Futures contract symbol used in trading and market data, e.g. front-month code provided by the exchange.",
                  "example": "SILZ5"
                },
                "instrument_id": {
                  "type": "string",
                  "description": "Unique instrument identifier for this futures contract in the Webull system or exchange.",
                  "example": "470059643"
                },
                "price": {
                  "type": "string",
                  "description": "Last traded price (last done) of the futures contract, quoted in the contract's trading currency (e.g. USD).",
                  "example": "47.35"
                },
                "open": {
                  "type": "string",
                  "description": "Session open price for this futures contract. Represents the first traded price of the current regular trading session. If no trade has occurred in the session, this field may be empty.",
                  "example": "48.17"
                },
                "high": {
                  "type": "string",
                  "description": "Session high price for this futures contract during the current regular trading session. If no trade has occurred in the session, this field may be empty.",
                  "example": "48.655"
                },
                "low": {
                  "type": "string",
                  "description": "Session low price for this futures contract during the current regular trading session. If no trade has occurred in the session, this field may be empty.",
                  "example": "46.855"
                },
                "pre_close": {
                  "type": "string",
                  "description": "Previous settlement/close price of the futures contract (typically the official settlement price of the previous trading day), quoted in the contract's trading currency.",
                  "example": "47.704"
                },
                "volume": {
                  "type": "string",
                  "description": "Accumulated traded volume for the current session, expressed in number of futures contracts. If no trading occurred in the session, this field may be empty.",
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
                  "description": "Timestamp of the last executed trade for this futures contract, expressed as Unix epoch time in milliseconds",
                  "format": "int64",
                  "example": 1761131406558
                },
                "open_interest": {
                  "type": "string",
                  "description": "Open interest, representing the total number of outstanding and unsettled futures contracts for this instrument, expressed in number of contracts.",
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
                "bid_size": {
                  "type": "string",
                  "description": "Best bid size, i.e. the total quantity available at the best bid price, expressed in number of futures contracts (whole contract units).",
                  "example": "1"
                },
                "ask_size": {
                  "type": "string",
                  "description": "Best ask size, i.e. the total quantity available at the best ask price, expressed in number of futures contracts (whole contract units).",
                  "example": "2"
                },
                "settle_date": {
                  "type": "string",
                  "description": "Settlement date of the latest official daily settlement, typically in ISO-8601 datetime format with timezone information.",
                  "example": "2025-10-21T12:00:00.000+0000"
                },
                "settle_price": {
                  "type": "string",
                  "description": "Settlement price of the latest official daily settlement, used for marking the contract to market and determining margin requirements, quoted in the contract's trading currency.",
                  "example": "47.704"
                }
              },
              "description": "Market snapshot data response object",
              "title": "FuturesSnapshotVo"
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
    "name": "List Futures Snapshots",
    "description": {
      "content": "Retrieves a real-time futures snapshot (latest price, change, volume).",
      "type": "text/plain"
    },
    "url": {
      "path": [
        "market-data",
        "futures",
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
            "content": "(Required) List of futures symbols, separated by commas; maximum 20 symbols per query. Example: SILZ5,6BM6.",
            "type": "text/plain"
          },
          "key": "symbols",
          "value": ""
        },
        {
          "disabled": false,
          "description": {
            "content": "(Required) Security type. Currently only `US_FUTURES` is supported for this interface.",
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
