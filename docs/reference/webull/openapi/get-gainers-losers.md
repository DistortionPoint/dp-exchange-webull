# List Top Gainers/Losers

• Function description: Top Gainers/Losers. The only difference between Top Gainers and Top Losers is that when order=CHANGE_RATIO, direction is passed as ASC (Losers) and DESC (Gainers). Returns top 200 results without pagination.<br/>• Frequency limit: Market-data interfaces rate limit is 600 requests per minute.

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
  "path": "/market-data/screeners/gainers-losers/list",
  "method": "get",
  "tags": [
    "Screeners"
  ],
  "description": "• Function description: Top Gainers/Losers. The only difference between Top Gainers and Top Losers is that when order=CHANGE_RATIO, direction is passed as ASC (Losers) and DESC (Gainers). Returns top 200 results without pagination.<br/>• Frequency limit: Market-data interfaces rate limit is 600 requests per minute.",
  "operationId": "getGainersLosers",
  "parameters": [
    {
      "name": "rank_type",
      "in": "query",
      "description": "Ranking time dimension that determines the calculation period for price change. Default: DAY_1.",
      "required": true,
      "schema": {
        "type": "string",
        "description": "Rank type for gainers/losers screener. Time period for ranking by price change percentage.",
        "enum": [
          "PRE_MARKET",
          "AFTER_MARKET",
          "MIN_3",
          "MIN_5",
          "DAY_1",
          "DAY_5",
          "MONTH_1",
          "MONTH_3",
          "WEEK_52"
        ]
      },
      "example": "DAY_1"
    },
    {
      "name": "category",
      "in": "query",
      "description": "Security market category. Default: US_STOCK.",
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
      "name": "sort_by",
      "in": "query",
      "description": "Secondary sort field for further ordering within the ranking. Default: CHANGE_RATIO.",
      "required": true,
      "schema": {
        "type": "string",
        "description": "Secondary sort field for screener API.",
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
          "VOLUME"
        ]
      },
      "example": "CHANGE_RATIO"
    },
    {
      "name": "direction",
      "in": "query",
      "description": "Sort direction. Default: DESC for Gainers, use ASC for Losers.",
      "required": false,
      "schema": {
        "type": "string",
        "description": "Sort direction for screener API.",
        "enum": [
          "ASC",
          "DESC"
        ]
      },
      "example": "DESC"
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
                  "description": "Unique identifier of the tradable instrument",
                  "example": "913256135"
                },
                "symbol": {
                  "type": "string",
                  "description": "Trading symbol of the financial instrument",
                  "example": "TSLA"
                },
                "name": {
                  "type": "string",
                  "description": "Full name of the instrument",
                  "example": "Tesla Inc"
                },
                "exchange_code": {
                  "type": "string",
                  "description": "Standardized exchange code",
                  "example": "NSQ"
                },
                "currency_code": {
                  "type": "string",
                  "description": "Denomination currency of the instrument (ISO 4217)",
                  "example": "USD"
                },
                "pre_close": {
                  "type": "string",
                  "description": "Previous trading day's closing price",
                  "example": "11.001"
                },
                "open": {
                  "type": "string",
                  "description": "Opening price for the current trading day",
                  "example": "11.001"
                },
                "high": {
                  "type": "string",
                  "description": "Intraday high price for the current trading day",
                  "example": "11.001"
                },
                "low": {
                  "type": "string",
                  "description": "Intraday low price for the current trading day",
                  "example": "11.001"
                },
                "close": {
                  "type": "string",
                  "description": "Latest traded price for the current trading day",
                  "example": "11.001"
                },
                "price": {
                  "type": "string",
                  "description": "Most recent quoted price within the selected time interval (pre market / post market / intraday)",
                  "example": "12.002"
                },
                "change": {
                  "type": "string",
                  "description": "Absolute price change within the selected time interval. Returns pre/post market change when in extended hours",
                  "example": "1.001"
                },
                "change_ratio": {
                  "type": "string",
                  "description": "Price change percentage within the selected time interval (decimal ratio). Returns pre/post market change percentage when in extended hours",
                  "example": "0.091"
                },
                "volume": {
                  "type": "string",
                  "description": "Cumulative traded volume for the current day (in shares)",
                  "example": "1111111"
                },
                "turnover": {
                  "type": "string",
                  "description": "Cumulative turnover amount in denomination currency. Not returned for US market under Nb authorization",
                  "example": "123434545656"
                },
                "turnover_rate": {
                  "type": "string",
                  "description": "Turnover rate as a decimal ratio (e.g. 0.05 represents 5%)",
                  "example": "0.011"
                },
                "market_value": {
                  "type": "string",
                  "description": "Total market capitalization in denomination currency",
                  "example": "12345678901"
                },
                "amplitude": {
                  "type": "string",
                  "description": "Price amplitude ((high - low) / pre_close) as a decimal ratio",
                  "example": "0.0909"
                },
                "relative_volume_10d": {
                  "type": "string",
                  "description": "Relative volume (current day volume / 10 day average volume)",
                  "example": "11.91"
                }
              },
              "description": "Stock information from gainers/losers screener API.",
              "title": "ScreenerStockVo"
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
    "name": "List Top Gainers/Losers",
    "description": {
      "content": "• Function description: Top Gainers/Losers. The only difference between Top Gainers and Top Losers is that when order=CHANGE_RATIO, direction is passed as ASC (Losers) and DESC (Gainers). Returns top 200 results without pagination.<br/>• Frequency limit: Market-data interfaces rate limit is 600 requests per minute.",
      "type": "text/plain"
    },
    "url": {
      "path": [
        "market-data",
        "screeners",
        "gainers-losers",
        "list"
      ],
      "host": [
        "{{baseUrl}}"
      ],
      "query": [
        {
          "disabled": false,
          "description": {
            "content": "(Required) Ranking time dimension that determines the calculation period for price change. Default: DAY_1.",
            "type": "text/plain"
          },
          "key": "rank_type",
          "value": ""
        },
        {
          "disabled": false,
          "description": {
            "content": "(Required) Security market category. Default: US_STOCK.",
            "type": "text/plain"
          },
          "key": "category",
          "value": ""
        },
        {
          "disabled": false,
          "description": {
            "content": "(Required) Secondary sort field for further ordering within the ranking. Default: CHANGE_RATIO.",
            "type": "text/plain"
          },
          "key": "sort_by",
          "value": ""
        },
        {
          "disabled": false,
          "description": {
            "content": "Sort direction. Default: DESC for Gainers, use ASC for Losers.",
            "type": "text/plain"
          },
          "key": "direction",
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
