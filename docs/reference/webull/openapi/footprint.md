# List Stock Footprints

Retrieves the most recent N footprint records for a stock by category and granularity. Required further subscription. Subscription Link([https://www.webullapp.com/center/mall](https://www.webullapp.com/center/mall))

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
  "path": "/market-data/stocks/footprints/list",
  "method": "get",
  "tags": [
    "Stocks Market Data"
  ],
  "description": "Retrieves the most recent N footprint records for a stock by category and granularity. Required further subscription. Subscription Link([https://www.webullapp.com/center/mall](https://www.webullapp.com/center/mall))",
  "operationId": "footprint",
  "parameters": [
    {
      "name": "symbols",
      "in": "query",
      "description": "List of security symbols, supports JSON array format, multiple symbols separated by commas; maximum 20 symbols per query.",
      "required": true,
      "schema": {
        "type": "string"
      },
      "example": "AAPL"
    },
    {
      "name": "category",
      "in": "query",
      "description": "Security type. Category values are as shown in the enum; Only US_STOCK type queries are supported.",
      "required": true,
      "schema": {
        "type": "string",
        "enum": [
          "US_STOCK"
        ]
      },
      "example": "US_STOCK"
    },
    {
      "name": "timespan",
      "in": "query",
      "description": "Supports granularities such as S5, S15, M1, M5, and M30.",
      "required": true,
      "schema": {
        "type": "string",
        "enum": [
          "S5",
          "S15",
          "M1",
          "M5",
          "M30"
        ]
      },
      "example": "S5"
    },
    {
      "name": "count",
      "in": "query",
      "description": "Number of bars, default 200, maximum limit 1200.",
      "required": false,
      "schema": {
        "type": "string",
        "description": "1-1200",
        "default": "200"
      },
      "example": 500
    },
    {
      "name": "real_time_required",
      "in": "query",
      "description": "Does it include the latest data? For candlesticks that are not yet finalized, the default is false (does not include). Only minute timespan is used.",
      "required": true,
      "schema": {
        "type": "string",
        "default": "false"
      },
      "example": true
    },
    {
      "name": "trading_sessions",
      "in": "query",
      "description": "Specify trading hours. OVN type not supported.",
      "required": false,
      "schema": {
        "type": "string",
        "enum": [
          "PRE",
          "RTH",
          "ATH",
          "OVN"
        ]
      },
      "example": "RTH"
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
                "symbol": {
                  "type": "string",
                  "description": "Security symbol",
                  "example": "AAPL"
                },
                "instrument_id": {
                  "type": "string",
                  "description": "Unique Identifier for Securities",
                  "example": "913256135"
                },
                "result": {
                  "type": "array",
                  "description": "Footprint chart candlestick chart",
                  "items": {
                    "type": "object",
                    "properties": {
                      "time": {
                        "type": "string",
                        "description": "Transaction date",
                        "example": "2025-09-30T05:47:00.000+0000"
                      },
                      "trading_session": {
                        "type": "string",
                        "description": "Trading Hours",
                        "example": "RTH"
                      },
                      "total": {
                        "type": "string",
                        "description": "The sum of the main buy and sell volumes",
                        "example": "1000"
                      },
                      "delta": {
                        "type": "string",
                        "description": "The difference in trading volume (primary buyers - primary sellers)",
                        "example": "200"
                      },
                      "buy_total": {
                        "type": "string",
                        "description": "Buy volume",
                        "example": "600"
                      },
                      "sell_total": {
                        "type": "string",
                        "description": "Main seller transaction volume",
                        "example": "400"
                      },
                      "buy_detail": {
                        "type": "object",
                        "additionalProperties": {
                          "type": "string",
                          "description": "The main purchase footprint details (quantity combined for items with the same price).",
                          "example": "{\"24.20\":\"100\",\"24.21\":\"60\"}"
                        },
                        "description": "The main purchase footprint details (quantity combined for items with the same price).",
                        "example": {
                          "24.20": "100",
                          "24.21": "60"
                        }
                      },
                      "sell_detail": {
                        "type": "object",
                        "additionalProperties": {
                          "type": "string",
                          "description": "The main seller's footprint shows details (quantities combined for the same price).",
                          "example": "{\"24.20\":\"50\",\"24.21\":\"50\"}"
                        },
                        "description": "The main seller's footprint shows details (quantities combined for the same price).",
                        "example": {
                          "24.20": "50",
                          "24.21": "50"
                        }
                      }
                    },
                    "description": "Footprint",
                    "title": "Footprint"
                  }
                }
              },
              "description": "Stock Footprint",
              "title": "FootprintVo"
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
    "name": "List Stock Footprints",
    "description": {
      "content": "Retrieves the most recent N footprint records for a stock by category and granularity. Required further subscription. Subscription Link([https://www.webullapp.com/center/mall](https://www.webullapp.com/center/mall))",
      "type": "text/plain"
    },
    "url": {
      "path": [
        "market-data",
        "stocks",
        "footprints",
        "list"
      ],
      "host": [
        "{{baseUrl}}"
      ],
      "query": [
        {
          "disabled": false,
          "description": {
            "content": "(Required) List of security symbols, supports JSON array format, multiple symbols separated by commas; maximum 20 symbols per query.",
            "type": "text/plain"
          },
          "key": "symbols",
          "value": ""
        },
        {
          "disabled": false,
          "description": {
            "content": "(Required) Security type. Category values are as shown in the enum; Only US_STOCK type queries are supported.",
            "type": "text/plain"
          },
          "key": "category",
          "value": ""
        },
        {
          "disabled": false,
          "description": {
            "content": "(Required) Supports granularities such as S5, S15, M1, M5, and M30.",
            "type": "text/plain"
          },
          "key": "timespan",
          "value": ""
        },
        {
          "disabled": false,
          "description": {
            "content": "Number of bars, default 200, maximum limit 1200.",
            "type": "text/plain"
          },
          "key": "count",
          "value": ""
        },
        {
          "disabled": false,
          "description": {
            "content": "(Required) Does it include the latest data? For candlesticks that are not yet finalized, the default is false (does not include). Only minute timespan is used.",
            "type": "text/plain"
          },
          "key": "real_time_required",
          "value": ""
        },
        {
          "disabled": false,
          "description": {
            "content": "Specify trading hours. OVN type not supported.",
            "type": "text/plain"
          },
          "key": "trading_sessions",
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
