# List Crypto Snapshots

Retrieve real-time market snapshot data for one or more crypto symbols.<br/><br/>The response includes key market indicators such as latest price, price change, price change percentage, bid/ask quotes, and other real-time metrics.<br/>Supports querying up to <b>20 symbols</b> per request.<br/><br/><b>Rate Limits:</b><br/>• 1 request per second per App Key<br/>• Market Data Global Limit: 600 requests per minute

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
  "path": "/market-data/crypto/snapshots/list",
  "method": "get",
  "tags": [
    "Crypto Market Data"
  ],
  "description": "Retrieve real-time market snapshot data for one or more crypto symbols.<br/><br/>The response includes key market indicators such as latest price, price change, price change percentage, bid/ask quotes, and other real-time metrics.<br/>Supports querying up to <b>20 symbols</b> per request.<br/><br/><b>Rate Limits:</b><br/>• 1 request per second per App Key<br/>• Market Data Global Limit: 600 requests per minute",
  "operationId": "cryptoSnapshot",
  "parameters": [
    {
      "name": "symbols",
      "in": "query",
      "description": "List of crypto trading symbols. Supports JSON array format or comma-separated values. Maximum 20 symbols.",
      "required": true,
      "schema": {
        "type": "string"
      },
      "example": "BTCUSD"
    },
    {
      "name": "category",
      "in": "query",
      "description": "Asset category (e.g., US_CRYPTO). Only crypto categories are supported for this API.",
      "required": true,
      "schema": {
        "type": "string",
        "enum": [
          "US_CRYPTO"
        ]
      },
      "example": "US_CRYPTO"
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
              "type": "object",
              "properties": {
                "instrument_id": {
                  "type": "string",
                  "description": "Instrument ID associated with the trading symbol",
                  "example": "913256135"
                },
                "symbol": {
                  "type": "string",
                  "description": "Trading symbol of the crypto",
                  "example": "BTCUSD"
                },
                "pre_close": {
                  "type": "string",
                  "description": "Previous closing price",
                  "example": "101.0"
                },
                "last_trade_time": {
                  "type": "integer",
                  "description": "Timestamp of the most recent trade (Unix timestamp in milliseconds).",
                  "format": "int64",
                  "example": 1640688000000
                },
                "price": {
                  "type": "string",
                  "description": "Latest traded price",
                  "example": "100.5"
                },
                "open": {
                  "type": "string",
                  "description": "Opening price of the current trading day. May be empty if no trades occurred.",
                  "example": "100.0"
                },
                "high": {
                  "type": "string",
                  "description": "Highest traded price of the current trading day. Empty if no trading occurred.",
                  "example": "105.0"
                },
                "low": {
                  "type": "string",
                  "description": "Lowest traded price of the current trading day. Empty if no trading occurred.",
                  "example": "99.0"
                },
                "change": {
                  "type": "string",
                  "description": "Absolute price change compared with the previous close",
                  "example": "1.0"
                },
                "change_ratio": {
                  "type": "string",
                  "description": "Price change ratio compared with the previous close",
                  "example": "0.05"
                },
                "quote_time": {
                  "type": "string",
                  "description": "Timestamp of the latest quote update (Unix timestamp in milliseconds).",
                  "example": "1761131401742"
                },
                "bid": {
                  "type": "string",
                  "description": "Best bid price (Bid 1)",
                  "example": "0.6217"
                },
                "bid_size": {
                  "type": "string",
                  "description": "The total volume (in lots/shares) of buy orders at the best bid price (buy-1 price)",
                  "example": "3817.29798008"
                },
                "ask": {
                  "type": "string",
                  "description": "Best ask price (Ask 1)",
                  "example": "0.6343"
                },
                "ask_size": {
                  "type": "string",
                  "description": "The total volume (in lots/shares) of sell orders at the best ask price (sell-1 price).",
                  "example": "1387.5"
                }
              },
              "description": "Real-time crypto market snapshot data",
              "title": "CryptoSnapshotVo"
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
    "name": "List Crypto Snapshots",
    "description": {
      "content": "Retrieve real-time market snapshot data for one or more crypto symbols.<br/><br/>The response includes key market indicators such as latest price, price change, price change percentage, bid/ask quotes, and other real-time metrics.<br/>Supports querying up to <b>20 symbols</b> per request.<br/><br/><b>Rate Limits:</b><br/>• 1 request per second per App Key<br/>• Market Data Global Limit: 600 requests per minute",
      "type": "text/plain"
    },
    "url": {
      "path": [
        "market-data",
        "crypto",
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
            "content": "(Required) List of crypto trading symbols. Supports JSON array format or comma-separated values. Maximum 20 symbols.",
            "type": "text/plain"
          },
          "key": "symbols",
          "value": ""
        },
        {
          "disabled": false,
          "description": {
            "content": "(Required) Asset category (e.g., US_CRYPTO). Only crypto categories are supported for this API.",
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
