# List Event Contract Markets

Retrieves event contract market instruments for the given series symbol.

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
  "path": "/trading/instruments/event-contracts/markets/list",
  "method": "get",
  "tags": [
    "Instruments"
  ],
  "description": "Retrieves event contract market instruments for the given series symbol.",
  "operationId": "eventMarketList",
  "parameters": [
    {
      "name": "series_symbol",
      "in": "query",
      "description": "Symbol that identifies this series.",
      "required": false,
      "schema": {
        "type": "string"
      },
      "example": "ECONOMICS"
    },
    {
      "name": "event_symbol",
      "in": "query",
      "description": "Symbol of the event events.",
      "required": false,
      "schema": {
        "type": "string"
      },
      "example": "KXRATECUTCOUNT-25DEC31"
    },
    {
      "name": "symbols",
      "in": "query",
      "description": "List of security symbols, maximum 100 symbols per query.",
      "required": false,
      "schema": {
        "type": "string"
      },
      "example": "KXRATECUTCOUNT-25DEC31-T8"
    },
    {
      "name": "expiration_date_after",
      "in": "query",
      "description": "Used to filter items whose expiration date is later than a specified date; the default selection is the current day (inclusive).",
      "required": false,
      "schema": {
        "type": "string"
      },
      "example": "2026-12-31"
    },
    {
      "name": "pagination_key",
      "in": "query",
      "description": "Pagination key from previous response for next page",
      "required": false,
      "schema": {
        "type": "string"
      },
      "example": "eyJ2IjoxLCJsYXN0SWQiOiIxNTMxMTgiLCJwYWdlSW5kZXgiOjAsInBhZ2VTaXplIjo1MDAsImNvbmRpdGlvbiI6Im51bGw7bnVsbDsifQ=="
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
                  "required": [
                    "can_close_early",
                    "event_name",
                    "event_symbol",
                    "expected_exp_date",
                    "fractionable",
                    "instrument_id",
                    "last_trading_date",
                    "latest_exp_date",
                    "name",
                    "payout_date",
                    "series_id",
                    "series_name",
                    "series_symbol",
                    "status",
                    "symbol",
                    "tradable_status",
                    "yes_condition"
                  ],
                  "type": "object",
                  "properties": {
                    "series_id": {
                      "type": "string",
                      "description": "ID that identifies this series.",
                      "example": "151750"
                    },
                    "series_symbol": {
                      "type": "string",
                      "description": "Symbol that identifies this series.",
                      "example": "KXRATECUTCOUNT"
                    },
                    "series_name": {
                      "type": "string",
                      "description": "Name that describes the series.",
                      "example": "Number of Rate Cuts"
                    },
                    "event_symbol": {
                      "type": "string",
                      "description": "Symbol that identifies this events.",
                      "example": "KXRATECUTCOUNT-26DEC31"
                    },
                    "event_name": {
                      "type": "string",
                      "description": "Name that describes the events.",
                      "example": "Number of rate cuts in 2026?"
                    },
                    "instrument_id": {
                      "type": "string",
                      "description": "Unique id of the event market.",
                      "example": "502257268"
                    },
                    "symbol": {
                      "type": "string",
                      "description": "Symbol of the event market.",
                      "example": "KXRATECUTCOUNT-25DEC31-T3"
                    },
                    "name": {
                      "type": "string",
                      "description": "Name of the event market.",
                      "example": "Will the Fed cut rates 3 times?"
                    },
                    "yes_condition": {
                      "type": "string",
                      "description": "Conditions for a 'Yes' outcome.",
                      "example": "Exactly 3 cuts"
                    },
                    "last_trading_date": {
                      "type": "string",
                      "description": "Last Notice Day.",
                      "example": "2025-12-31"
                    },
                    "status": {
                      "type": "string",
                      "description": "Listing status.",
                      "example": "LISTING",
                      "enum": [
                        "NOT_SET",
                        "LISTING",
                        "DELISTING",
                        "OTHER",
                        "UNRECOGNIZED"
                      ]
                    },
                    "tradable_status": {
                      "type": "string",
                      "description": "Tradable status: OC (Tradable), CO (Liquidate only), NT (Non-Tradable)",
                      "example": "NT",
                      "enum": [
                        "OC",
                        "CO",
                        "NT"
                      ]
                    },
                    "can_close_early": {
                      "type": "boolean",
                      "description": "Can the contract close early?",
                      "example": true
                    },
                    "expected_exp_date": {
                      "type": "string",
                      "description": "Expected expiration date of contract.",
                      "example": "2025-12-31"
                    },
                    "latest_exp_date": {
                      "type": "string",
                      "description": "Latest expiration date.",
                      "example": "2026-01-01"
                    },
                    "payout_date": {
                      "type": "string",
                      "description": "Settlement/Payment Date.",
                      "example": "2025-12-31"
                    },
                    "fractionable": {
                      "type": "boolean",
                      "description": "Support fragmented event contracts.",
                      "example": true
                    },
                    "price_ranges": {
                      "type": "array",
                      "description": "Price range.",
                      "items": {
                        "required": [
                          "end",
                          "start",
                          "step"
                        ],
                        "type": "object",
                        "properties": {
                          "start": {
                            "type": "string",
                            "description": "Start price.",
                            "example": "0.0"
                          },
                          "end": {
                            "type": "string",
                            "description": "End price.",
                            "example": "1.0"
                          },
                          "step": {
                            "type": "string",
                            "description": "Step length.",
                            "example": "0.01"
                          }
                        },
                        "description": "Price range.",
                        "title": "PriceRange"
                      }
                    }
                  },
                  "description": "Event market",
                  "title": "EventMarketVo"
                }
              },
              "pagination_key": {
                "type": "string",
                "description": "Pagination key for next page. If absent, indicates this is the last page.",
                "example": "eyJ2IjoxLCJsYXN0SWQiOiI5MTMyNDQ3NjkiLCJwYWdlSW===="
              }
            },
            "description": "Paginated result with cursor-based pagination",
            "title": "PaginatedResultVoEventMarketVo"
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
    "name": "List Event Contract Markets",
    "description": {
      "content": "Retrieves event contract market instruments for the given series symbol.",
      "type": "text/plain"
    },
    "url": {
      "path": [
        "trading",
        "instruments",
        "event-contracts",
        "markets",
        "list"
      ],
      "host": [
        "{{baseUrl}}"
      ],
      "query": [
        {
          "disabled": false,
          "description": {
            "content": "Symbol that identifies this series.",
            "type": "text/plain"
          },
          "key": "series_symbol",
          "value": ""
        },
        {
          "disabled": false,
          "description": {
            "content": "Symbol of the event events.",
            "type": "text/plain"
          },
          "key": "event_symbol",
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
            "content": "Used to filter items whose expiration date is later than a specified date; the default selection is the current day (inclusive).",
            "type": "text/plain"
          },
          "key": "expiration_date_after",
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
