# Get Market Sector Detail

• Function description: Get stock list and statistics for a specific sector.<br/>• Frequency limit: Market-data interfaces rate limit is 600 requests per minute.

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
  "path": "/market-data/screeners/market-sectors/get",
  "method": "get",
  "tags": [
    "Screeners"
  ],
  "description": "• Function description: Get stock list and statistics for a specific sector.<br/>• Frequency limit: Market-data interfaces rate limit is 600 requests per minute.",
  "operationId": "getMarketSectorsDetail",
  "parameters": [
    {
      "name": "sector_id",
      "in": "query",
      "description": "Sector ID",
      "required": true,
      "schema": {
        "type": "string"
      },
      "example": 6391
    },
    {
      "name": "category",
      "in": "query",
      "description": "Security market category",
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
      "name": "period",
      "in": "query",
      "description": "Statistics period, default is D1.",
      "required": false,
      "schema": {
        "type": "string",
        "description": "Statistics period for market sectors.",
        "enum": [
          "D1",
          "D5",
          "MO1",
          "MO3"
        ]
      },
      "example": "D1"
    },
    {
      "name": "sort_by",
      "in": "query",
      "description": "Sort field, default is CHANGE_RATIO.",
      "required": false,
      "schema": {
        "type": "string",
        "description": "Sort fields for High Dividend, Market Sectors Detail, and 52 Week High/Low.",
        "enum": [
          "CHANGE_RATIO",
          "RELATIVE_VOLUME_10D",
          "MARKET_VALUE",
          "CLOSE",
          "PRICE",
          "PE_TTM",
          "HIGH",
          "LOW",
          "AMPLITUDE",
          "TURNOVER",
          "VOLUME",
          "YIELD",
          "DIVIDEND"
        ]
      },
      "example": "CHANGE_RATIO"
    },
    {
      "name": "direction",
      "in": "query",
      "description": "Sort direction. Default: ASC.",
      "required": false,
      "schema": {
        "type": "string",
        "description": "Sort direction for screener API.",
        "enum": [
          "ASC",
          "DESC"
        ]
      },
      "example": "ASC"
    },
    {
      "name": "pagination_key",
      "in": "query",
      "description": "Pagination key from previous response for next page",
      "required": false,
      "schema": {
        "type": "string"
      },
      "example": "eyJ2IjoxLCJsYXN0SWQiOiIwIiwicGFnZUluZGV4IjoxLCJwYWd"
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
            "type": "object",
            "properties": {
              "id": {
                "type": "string",
                "description": "Sector ID",
                "example": "6391"
              },
              "name": {
                "type": "string",
                "description": "Sector Name",
                "example": "Energy - Fossil Fuels"
              },
              "change_ratio": {
                "type": "string",
                "description": "Price change ratio",
                "example": "0.013"
              },
              "declined": {
                "type": "string",
                "description": "Number of stocks that have fallen",
                "example": "39"
              },
              "advanced": {
                "type": "string",
                "description": "Number of stocks that have risen",
                "example": "110"
              },
              "flat": {
                "type": "string",
                "description": "Number of stocks with a price change of 0",
                "example": "107"
              },
              "data": {
                "type": "array",
                "description": "List of stocks in the sector",
                "items": {
                  "type": "object",
                  "properties": {
                    "instrument_id": {
                      "type": "string",
                      "description": "Security ID",
                      "example": "913256135"
                    },
                    "category": {
                      "type": "string",
                      "description": "Security category",
                      "example": "US_STOCK"
                    },
                    "currency": {
                      "type": "string",
                      "description": "Currency code",
                      "example": "USD"
                    },
                    "name": {
                      "type": "string",
                      "description": "Security name",
                      "example": "Tesla Inc"
                    },
                    "symbol": {
                      "type": "string",
                      "description": "Security symbol",
                      "example": "TSLA"
                    },
                    "exchange_code": {
                      "type": "string",
                      "description": "Exchange code",
                      "example": "NSQ"
                    },
                    "close": {
                      "type": "string",
                      "description": "Latest intraday price",
                      "example": "12.01"
                    },
                    "change_ratio": {
                      "type": "string",
                      "description": "Price change ratio",
                      "example": "0.0111"
                    },
                    "price": {
                      "type": "string",
                      "description": "Latest price",
                      "example": "11.01"
                    },
                    "volume": {
                      "type": "string",
                      "description": "Trade volume",
                      "example": "1111111"
                    },
                    "market_value": {
                      "type": "string",
                      "description": "Market Value",
                      "example": "12345678901"
                    },
                    "turnover_rate": {
                      "type": "string",
                      "description": "Turnover Rate",
                      "example": "0.1111"
                    },
                    "amplitude": {
                      "type": "string",
                      "description": "Amplitude Ratio",
                      "example": "0.1111"
                    },
                    "high": {
                      "type": "string",
                      "description": "Today's high",
                      "example": "12.11"
                    },
                    "low": {
                      "type": "string",
                      "description": "Today's low",
                      "example": "11.01"
                    }
                  },
                  "description": "Stock in a market sector detail",
                  "title": "SectorDetailStockVo"
                }
              },
              "pagination_key": {
                "type": "string",
                "description": "Pagination key for next page. If absent, indicates this is the last page.",
                "example": "eyJ2IjoxLCJsYXN0SWQiOiIwIiwicGFnZUluZGV4IjoxLCJwYWd"
              }
            },
            "description": "Market Sectors Detail result",
            "title": "MarketSectorsDetailVo"
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
    "name": "Get Market Sector Detail",
    "description": {
      "content": "• Function description: Get stock list and statistics for a specific sector.<br/>• Frequency limit: Market-data interfaces rate limit is 600 requests per minute.",
      "type": "text/plain"
    },
    "url": {
      "path": [
        "market-data",
        "screeners",
        "market-sectors",
        "get"
      ],
      "host": [
        "{{baseUrl}}"
      ],
      "query": [
        {
          "disabled": false,
          "description": {
            "content": "(Required) Sector ID",
            "type": "text/plain"
          },
          "key": "sector_id",
          "value": ""
        },
        {
          "disabled": false,
          "description": {
            "content": "(Required) Security market category",
            "type": "text/plain"
          },
          "key": "category",
          "value": ""
        },
        {
          "disabled": false,
          "description": {
            "content": "Statistics period, default is D1.",
            "type": "text/plain"
          },
          "key": "period",
          "value": ""
        },
        {
          "disabled": false,
          "description": {
            "content": "Sort field, default is CHANGE_RATIO.",
            "type": "text/plain"
          },
          "key": "sort_by",
          "value": ""
        },
        {
          "disabled": false,
          "description": {
            "content": "Sort direction. Default: ASC.",
            "type": "text/plain"
          },
          "key": "direction",
          "value": ""
        },
        {
          "disabled": false,
          "description": {
            "content": "Pagination key from previous response for next page",
            "type": "text/plain"
          },
          "key": "pagination_key",
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
