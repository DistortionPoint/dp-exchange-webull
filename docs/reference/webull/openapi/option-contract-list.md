# List Option Contracts

Retrieves option contracts filtered by underlying symbol, status and other attributes. Contains static contract information.

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
  "path": "/trading/instruments/options/contracts/list",
  "method": "get",
  "tags": [
    "Instruments"
  ],
  "description": "Retrieves option contracts filtered by underlying symbol, status and other attributes. Contains static contract information.",
  "operationId": "optionContractList",
  "parameters": [
    {
      "name": "category",
      "in": "query",
      "description": "Option category. Currently only US_OPTION is supported.",
      "required": true,
      "schema": {
        "type": "string",
        "description": "Option Category<br/>US_OPTION - US option<br/>",
        "enum": [
          "US_OPTION"
        ]
      },
      "example": "US_OPTION"
    },
    {
      "name": "option_symbols",
      "in": "query",
      "description": "Option symbols, multiple separated by commas.",
      "required": false,
      "schema": {
        "type": "string"
      },
      "example": "AAPL250620C00150000,SPX241220P04200000"
    },
    {
      "name": "underlying_symbols",
      "in": "query",
      "description": "Underlying symbols, multiple separated by commas.",
      "required": false,
      "schema": {
        "type": "string"
      },
      "example": "AAPL,MSFT"
    },
    {
      "name": "status",
      "in": "query",
      "description": "Contract status, default LISTING. Enum: LISTING, DELISTING.",
      "required": false,
      "schema": {
        "type": "string"
      },
      "example": "LISTING"
    },
    {
      "name": "start_date",
      "in": "query",
      "description": "Exact expiration date, format: YYYY-MM-DD.",
      "required": false,
      "schema": {
        "type": "string"
      },
      "example": "2025-06-20"
    },
    {
      "name": "end_date",
      "in": "query",
      "description": "Expiration date lower bound (inclusive), format: YYYY-MM-DD.",
      "required": false,
      "schema": {
        "type": "string"
      },
      "example": "2025-06-20"
    },
    {
      "name": "root_symbol",
      "in": "query",
      "description": "Root symbol filter (series symbol, e.g. SPXW). Mainly used for index options and post-CA non-standard contracts.",
      "required": false,
      "schema": {
        "type": "string"
      },
      "example": "SPXW"
    },
    {
      "name": "option_type",
      "in": "query",
      "description": "Contract type: CALL / PUT.",
      "required": false,
      "schema": {
        "type": "string"
      },
      "example": "CALL"
    },
    {
      "name": "style",
      "in": "query",
      "description": "Exercise style: AMERICAN / EUROPEAN.",
      "required": false,
      "schema": {
        "type": "string"
      },
      "example": "AMERICAN"
    },
    {
      "name": "strike_price_gte",
      "in": "query",
      "description": "Strike price lower bound (inclusive).",
      "required": false,
      "schema": {
        "type": "string"
      },
      "example": 150
    },
    {
      "name": "strike_price_lte",
      "in": "query",
      "description": "Strike price upper bound (inclusive).",
      "required": false,
      "schema": {
        "type": "string"
      },
      "example": 200
    },
    {
      "name": "ppind",
      "in": "query",
      "description": "Penny Program Indicator: true = Penny Pilot contract, false = non-Penny Pilot.",
      "required": false,
      "schema": {
        "type": "boolean"
      },
      "example": true
    },
    {
      "name": "show_deliverables",
      "in": "query",
      "description": "Whether to return deliverables array in response: TRUE / FALSE, default FALSE.",
      "required": false,
      "schema": {
        "type": "boolean"
      },
      "example": "FALSE"
    },
    {
      "name": "pagination_key",
      "in": "query",
      "description": "Pagination key from previous response for next page. Not required for first request.",
      "required": false,
      "schema": {
        "type": "string"
      },
      "example": "eyJ2IjoxLCJsYXN0SWQiOiIxMDMyNTExMTY0IiwicGFnZUluZGV4IjowLCJwYWdlU2l6ZSI6MTAwMCwiY29uZGl0aW9uIjoiVVNfT1BUSU9OO251bGw7bnVsbDtMSVNUSU5HO251bGw7bnVsbDtudWxsO251bGw7bnVsbDtudWxsO251bGw7bnVsbDtmYWxzZTsifQ=="
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
                    "instrument_id": {
                      "type": "string",
                      "description": "Contract unique identifier",
                      "example": "1038392011"
                    },
                    "symbol": {
                      "type": "string",
                      "description": "OCC contract symbol",
                      "example": "AAPL250620C00150000"
                    },
                    "status": {
                      "type": "string",
                      "description": "Contract status: LISTING, DELISTING",
                      "example": "LISTING"
                    },
                    "tradable_status": {
                      "type": "string",
                      "description": "Trading restriction: OC (Tradable), CO (Liquidate only), NT (Non-Tradable)",
                      "example": "OC"
                    },
                    "expiration_date": {
                      "type": "string",
                      "description": "Expiration date (effective expiration date after CA events), format: YYYY-MM-DD",
                      "example": "2025-06-20"
                    },
                    "root_symbol": {
                      "type": "string",
                      "description": "Root symbol (series symbol). For most equity options, same as underlying_symbol; may differ for index and post-CA contracts (e.g., SPXW)",
                      "example": "AAPL"
                    },
                    "underlying_symbol": {
                      "type": "string",
                      "description": "Underlying symbol",
                      "example": "AAPL"
                    },
                    "underlying_instrument_id": {
                      "type": "string",
                      "description": "Underlying instrument id",
                      "example": "913256135"
                    },
                    "underlying_type": {
                      "type": "string",
                      "description": "Underlying type: EQUITY_PUT_OPTION / EQUITY_CALL_OPTION / INDEX_CALL_OPTION / ETF_CALL_OPTION / ETF_PUT_OPTION",
                      "example": "EQUITY_CALL_OPTION"
                    },
                    "option_type": {
                      "type": "string",
                      "description": "Contract type: CALL / PUT",
                      "example": "CALL"
                    },
                    "style": {
                      "type": "string",
                      "description": "Exercise style: AMERICAN / EUROPEAN",
                      "example": "AMERICAN"
                    },
                    "strike_price": {
                      "type": "string",
                      "description": "Strike price",
                      "example": "150.0"
                    },
                    "multiplier": {
                      "type": "string",
                      "description": "Contract multiplier, typically 100 for US equity options",
                      "example": "100"
                    },
                    "settlement_method": {
                      "type": "string",
                      "description": "Settlement method: PHYSICAL / CASH",
                      "example": "PHYSICAL"
                    },
                    "expired_cycle": {
                      "type": "string",
                      "description": "Expiration cycle: DAILY / WEEKLY / MONTHLY / QUARTERLY / EOM",
                      "example": "MONTHLY"
                    },
                    "ppind": {
                      "type": "boolean",
                      "description": "Penny Program Indicator: true = Penny Pilot, false = non-Penny Pilot",
                      "example": true
                    },
                    "currency": {
                      "type": "string",
                      "description": "Pricing currency",
                      "example": "USD"
                    },
                    "def_type": {
                      "type": "string",
                      "description": "Definition type: STANDARD / BINARY / FLEX",
                      "example": "STANDARD"
                    },
                    "listed_exchanges": {
                      "type": "array",
                      "description": "Listed exchanges",
                      "items": {
                        "type": "string",
                        "description": "Listed exchanges"
                      }
                    },
                    "deliverables": {
                      "type": "array",
                      "description": "Deliverables configuration; after CA a single contract may correspond to multiple underlyings + cash",
                      "items": {
                        "type": "object",
                        "properties": {
                          "asset_type": {
                            "type": "string",
                            "description": "Asset type. settlement_method=CAFX/CFR/CADF returns CASH; settlement_method=BTOB/CCC/POST/PHYS returns EQUITY",
                            "example": "EQUITY"
                          },
                          "symbol": {
                            "type": "string",
                            "description": "Deliverable underlying symbol",
                            "example": "AAPL"
                          },
                          "instrument_id": {
                            "type": "string",
                            "description": "Deliverable underlying instrument id",
                            "example": "913256135"
                          },
                          "amount": {
                            "type": "string",
                            "description": "Delivery amount: number of shares when type=EQUITY, cash amount when type=CASH",
                            "example": "0"
                          },
                          "allocation_percentage": {
                            "type": "string",
                            "description": "Allocation percentage (0-100)",
                            "example": "100"
                          },
                          "settlement_type": {
                            "type": "string",
                            "description": "Settlement cycle: T_0 / T_1 / T_2 / T_3 / T_4",
                            "example": "T_1"
                          },
                          "settlement_method": {
                            "type": "string",
                            "description": "Clearing method: PHYSICAL (BTOB) / CASH_DIFF (CADF) / CASH_FIXED (CAFX) / CCC / CASH_FIXED_RETURN (CFR) / POSITIONAL (POST)",
                            "example": "PHYSICAL"
                          },
                          "settlement_status": {
                            "type": "string",
                            "description": "Settlement status: DELAYED / REGULAR",
                            "example": "REGULAR"
                          }
                        },
                        "description": "Option Contract Deliverable",
                        "title": "OptionContractDeliverable"
                      }
                    }
                  },
                  "description": "Option Contract Information",
                  "title": "OptionContractResult"
                }
              },
              "pagination_key": {
                "type": "string",
                "description": "Pagination key for next page. If absent, indicates this is the last page.",
                "example": "eyJ2IjoxLCJsYXN0SWQiOiI5MTMyNDQ3NjkiLCJwYWdlSW===="
              }
            },
            "description": "Paginated result with cursor-based pagination",
            "title": "PaginatedResultVoOptionContractResult"
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
    "name": "List Option Contracts",
    "description": {
      "content": "Retrieves option contracts filtered by underlying symbol, status and other attributes. Contains static contract information.",
      "type": "text/plain"
    },
    "url": {
      "path": [
        "trading",
        "instruments",
        "options",
        "contracts",
        "list"
      ],
      "host": [
        "{{baseUrl}}"
      ],
      "query": [
        {
          "disabled": false,
          "description": {
            "content": "(Required) Option category. Currently only US_OPTION is supported.",
            "type": "text/plain"
          },
          "key": "category",
          "value": ""
        },
        {
          "disabled": false,
          "description": {
            "content": "Option symbols, multiple separated by commas.",
            "type": "text/plain"
          },
          "key": "option_symbols",
          "value": ""
        },
        {
          "disabled": false,
          "description": {
            "content": "Underlying symbols, multiple separated by commas.",
            "type": "text/plain"
          },
          "key": "underlying_symbols",
          "value": ""
        },
        {
          "disabled": false,
          "description": {
            "content": "Contract status, default LISTING. Enum: LISTING, DELISTING.",
            "type": "text/plain"
          },
          "key": "status",
          "value": ""
        },
        {
          "disabled": false,
          "description": {
            "content": "Exact expiration date, format: YYYY-MM-DD.",
            "type": "text/plain"
          },
          "key": "start_date",
          "value": ""
        },
        {
          "disabled": false,
          "description": {
            "content": "Expiration date lower bound (inclusive), format: YYYY-MM-DD.",
            "type": "text/plain"
          },
          "key": "end_date",
          "value": ""
        },
        {
          "disabled": false,
          "description": {
            "content": "Root symbol filter (series symbol, e.g. SPXW). Mainly used for index options and post-CA non-standard contracts.",
            "type": "text/plain"
          },
          "key": "root_symbol",
          "value": ""
        },
        {
          "disabled": false,
          "description": {
            "content": "Contract type: CALL / PUT.",
            "type": "text/plain"
          },
          "key": "option_type",
          "value": ""
        },
        {
          "disabled": false,
          "description": {
            "content": "Exercise style: AMERICAN / EUROPEAN.",
            "type": "text/plain"
          },
          "key": "style",
          "value": ""
        },
        {
          "disabled": false,
          "description": {
            "content": "Strike price lower bound (inclusive).",
            "type": "text/plain"
          },
          "key": "strike_price_gte",
          "value": ""
        },
        {
          "disabled": false,
          "description": {
            "content": "Strike price upper bound (inclusive).",
            "type": "text/plain"
          },
          "key": "strike_price_lte",
          "value": ""
        },
        {
          "disabled": false,
          "description": {
            "content": "Penny Program Indicator: true = Penny Pilot contract, false = non-Penny Pilot.",
            "type": "text/plain"
          },
          "key": "ppind",
          "value": ""
        },
        {
          "disabled": false,
          "description": {
            "content": "Whether to return deliverables array in response: TRUE / FALSE, default FALSE.",
            "type": "text/plain"
          },
          "key": "show_deliverables",
          "value": ""
        },
        {
          "disabled": false,
          "description": {
            "content": "Pagination key from previous response for next page. Not required for first request.",
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
