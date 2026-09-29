# List Stock Instruments

Retrieves profile information for one or more stock instruments.

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
  "path": "/trading/instruments/stocks/profiles/list",
  "method": "get",
  "tags": [
    "Instruments"
  ],
  "description": "Retrieves profile information for one or more stock instruments.",
  "operationId": "instrumentList",
  "parameters": [
    {
      "name": "category",
      "in": "query",
      "description": "Security type.",
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
      "name": "symbols",
      "in": "query",
      "description": "List of security symbols, maximum 100 symbols per query.",
      "required": false,
      "schema": {
        "type": "string"
      },
      "example": "AAPL,TSLA"
    },
    {
      "name": "status",
      "in": "query",
      "description": "Tradable status: OC (Tradable), CO (Liquidate only), NT (Non-Tradable)",
      "required": false,
      "schema": {
        "type": "string",
        "description": "Tradable status: OC (Tradable), CO (Liquidate only), NT (Non-Tradable)",
        "enum": [
          "OC",
          "CO",
          "NT"
        ]
      },
      "example": "CO"
    },
    {
      "name": "sub_category",
      "in": "query",
      "description": "Sub-category of the instrument. Only effective when symbols is not specified. When category = US_STOCK, supported values: COMMON_STOCK, ETF, PREFERRED_STOCK, WARRANT, UNITS, RIGHT. If not specified, returns all sub-categories.",
      "required": false,
      "schema": {
        "type": "string",
        "description": "Sub-category of the instrument.",
        "enum": [
          "COMMON_STOCK",
          "ETF",
          "PREFERRED_STOCK",
          "WARRANT",
          "UNITS",
          "RIGHT"
        ]
      },
      "example": "ETF"
    },
    {
      "name": "pagination_key",
      "in": "query",
      "description": "Pagination key from previous response for next page",
      "required": false,
      "schema": {
        "type": "string"
      },
      "example": "eyJ2IjoxLCJsYXN0SWQiOiI5MTMyNDQ3NjkiLCJwYWdlSW===="
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
              "data": {
                "type": "array",
                "description": "Result data list",
                "items": {
                  "type": "object",
                  "properties": {
                    "name": {
                      "type": "string",
                      "description": "Symbol name, e.g. Apple",
                      "example": "APPLE INC"
                    },
                    "instrument_id": {
                      "type": "string",
                      "description": "Unique identifier of the security",
                      "example": "10152734329"
                    },
                    "exchange_code": {
                      "type": "string",
                      "description": "Exchange code, e.g. CCC",
                      "example": "NSQ"
                    },
                    "category": {
                      "type": "string",
                      "description": "Instrument type, e.g. US_STOCK",
                      "example": "US_STOCK",
                      "enum": [
                        "US_STOCK"
                      ]
                    },
                    "symbol": {
                      "type": "string",
                      "description": "Symbol of the instrument",
                      "example": "AAPL"
                    },
                    "status": {
                      "type": "string",
                      "description": "Tradable status: OC (Tradable), CO (Liquidate only), NT (Non-Tradable)",
                      "example": "OC",
                      "enum": [
                        "OC",
                        "CO",
                        "NT"
                      ]
                    },
                    "shortable": {
                      "type": "boolean",
                      "description": "Instrument is shortable or not",
                      "example": false
                    },
                    "fractionable": {
                      "type": "boolean",
                      "description": "Instrument is fractionable or not ",
                      "example": false
                    },
                    "marginable": {
                      "type": "boolean",
                      "description": "Instrument is marginable or not",
                      "example": false
                    },
                    "overnight_trading_supported": {
                      "type": "boolean",
                      "description": "Instrument support overnight trading or not ",
                      "example": false
                    },
                    "margin_requirement_long": {
                      "type": "string",
                      "description": "Margin requirement ratio for long position ",
                      "example": "0.5"
                    },
                    "margin_requirement_short": {
                      "type": "string",
                      "description": "Margin requirement ratio for short position ",
                      "example": "0.5"
                    },
                    "intraday_margin_long": {
                      "type": "string",
                      "description": "Intraday margin requirement ratio for long position ",
                      "example": "0.5"
                    },
                    "intraday_margin_short": {
                      "type": "string",
                      "description": "Intraday margin requirement ratio for short position ",
                      "example": "0.5"
                    },
                    "maintenance_margin_long": {
                      "type": "string",
                      "description": "Maintenance margin requirement ratio for long position ",
                      "example": "0.5"
                    },
                    "maintenance_margin_short": {
                      "type": "string",
                      "description": "Maintenance margin requirement ratio for short position ",
                      "example": "0.5"
                    },
                    "easy_to_borrow": {
                      "type": "boolean",
                      "description": "Instrument is easy to borrow or not",
                      "example": false
                    },
                    "lot_size": {
                      "type": "string",
                      "description": "Lot size",
                      "example": "1.0"
                    },
                    "currency": {
                      "type": "string",
                      "description": "currency",
                      "example": "USD"
                    },
                    "sub_category": {
                      "type": "string",
                      "description": "Sub-category of the instrument.",
                      "example": "ETF",
                      "enum": [
                        "COMMON_STOCK",
                        "ETF",
                        "PREFERRED_STOCK",
                        "WARRANT",
                        "UNITS",
                        "RIGHT"
                      ]
                    },
                    "etf_leveraged_flag": {
                      "type": "string",
                      "description": "ETF leveraged flag",
                      "example": "NO"
                    },
                    "etf_leveraged_factor": {
                      "type": "string",
                      "description": "ETF leveraged factor",
                      "example": "0"
                    },
                    "crypto_etf": {
                      "type": "boolean",
                      "description": "Whether the instrument is a crypto ETF",
                      "example": false
                    }
                  },
                  "description": "Instrument Information",
                  "title": "InstrumentStockDetailVO"
                }
              },
              "pagination_key": {
                "type": "string",
                "description": "Pagination key for next page. If absent, indicates this is the last page.",
                "example": "eyJ2IjoxLCJsYXN0SWQiOiI5MTMyNDQ3NjkiLCJwYWdlSW===="
              }
            },
            "description": "Paginated result with cursor-based pagination",
            "title": "PaginatedResultVoInstrumentStockDetailVO"
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
    "name": "List Stock Instruments",
    "description": {
      "content": "Retrieves profile information for one or more stock instruments.",
      "type": "text/plain"
    },
    "url": {
      "path": [
        "trading",
        "instruments",
        "stocks",
        "profiles",
        "list"
      ],
      "host": [
        "{{baseUrl}}"
      ],
      "query": [
        {
          "disabled": false,
          "description": {
            "content": "(Required) Security type.",
            "type": "text/plain"
          },
          "key": "category",
          "value": ""
        },
        {
          "disabled": false,
          "description": {
            "content": "List of security symbols, maximum 100 symbols per query.",
            "type": "text/plain"
          },
          "key": "symbols",
          "value": ""
        },
        {
          "disabled": false,
          "description": {
            "content": "Tradable status: OC (Tradable), CO (Liquidate only), NT (Non-Tradable)",
            "type": "text/plain"
          },
          "key": "status",
          "value": ""
        },
        {
          "disabled": false,
          "description": {
            "content": "Sub-category of the instrument. Only effective when symbols is not specified. When category = US_STOCK, supported values: COMMON_STOCK, ETF, PREFERRED_STOCK, WARRANT, UNITS, RIGHT. If not specified, returns all sub-categories.",
            "type": "text/plain"
          },
          "key": "sub_category",
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
