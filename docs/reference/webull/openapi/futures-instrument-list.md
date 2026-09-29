# List Futures Contracts

Retrieves profile information for one or multiple futures trading instruments by symbol(s).

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
  "path": "/trading/instruments/futures/contracts/list",
  "method": "get",
  "tags": [
    "Instruments"
  ],
  "description": "Retrieves profile information for one or multiple futures trading instruments by symbol(s).",
  "operationId": "futuresInstrumentList",
  "parameters": [
    {
      "name": "category",
      "in": "query",
      "description": "Security type. Fixed value: US_FUTURES.",
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
      "name": "symbols",
      "in": "query",
      "description": "List of futures trading symbols. Accepts JSON array format or comma-separated strings. Maximum of 100 symbols per request. Note: Either symbols or code must be provided. ",
      "required": false,
      "schema": {
        "type": "string"
      },
      "example": "ESZ5,NQZ5"
    },
    {
      "name": "code",
      "in": "query",
      "description": "List of futures trading code, remark:Either 'symbols' or 'code' must be present.",
      "required": false,
      "schema": {
        "type": "string"
      },
      "example": "ES"
    },
    {
      "name": "status",
      "in": "query",
      "description": "Tradable Status<br/>OC - Tradable: Security is available for trading<br/>CO - Liquidate only: Security can only be sold, no purchases allowed<br/>NT - Non-Tradable: Security cannot be traded<br/>Default: OC",
      "required": false,
      "schema": {
        "type": "string"
      },
      "example": "OC"
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
                  "description": "Futures contract symbol used in trading and market data, e.g. front-month or continuous contract code such as ESZ5, ESmain, etc.",
                  "example": "ESZ5"
                },
                "instrument_id": {
                  "type": "string",
                  "description": "Unique identifier for this futures instrument in the Webull system or exchange. If the symbol represents a main/continuous contract, this ID is for the main contract itself. For order placement, it needs to be mapped to the actual month contract ID (see `contractId`).",
                  "example": "470059643"
                },
                "exchange_code": {
                  "type": "string",
                  "description": "Exchange code, for example: CBOE, GLOBEX, XNYM, XCEC, XCME, XCBT, CDE.",
                  "example": "XCME"
                },
                "code": {
                  "type": "string",
                  "description": "Code for this futures contract, for example: ES.",
                  "example": "ES"
                },
                "name": {
                  "type": "string",
                  "description": "Display name of the futures contract.",
                  "example": "E-mini S&P 500 Futures Dec 2025"
                },
                "product_class_id": {
                  "type": "integer",
                  "description": "Futures product class id, For example: 2",
                  "format": "int32",
                  "example": 2
                },
                "product_class_name": {
                  "type": "string",
                  "description": "Futures product class name, For example: 2",
                  "example": "Equities"
                },
                "status": {
                  "type": "string",
                  "description": "Tradable status: OC (Tradable), CO (Liquidate only), NT (Non-Tradable)  OC, CO, NT",
                  "example": "OC"
                },
                "currency": {
                  "type": "string",
                  "description": "Trading currency of this futures contract, for example: USD.",
                  "example": "USD"
                },
                "contract_month": {
                  "type": "string",
                  "description": "Contract delivery month in the format yyyyMM, for example: 202512 means Dec 2025 (year + month).",
                  "example": "202512"
                },
                "settlement_date": {
                  "type": "string",
                  "description": "Final settlement (delivery) date of the contract in the format yyyy-MM-dd, for example: 2025-12-29.",
                  "example": "2025-12-29"
                },
                "size": {
                  "type": "string",
                  "description": "Contract size (multiplier). The notional value of one contract equals futures price multiplied by this size. ",
                  "example": "50.0"
                },
                "unit": {
                  "type": "string",
                  "description": "Contract unit, describing the pricing unit and quantity (for example: index points x USD).",
                  "example": "1-index points",
                  "enum": [
                    "1 - Index points",
                    "2 - Hong Kong dollars",
                    "3 - US dollars",
                    "4 - Bushels",
                    "5 - Bushels 2",
                    "6 - Futures contract",
                    "7 - Short tons, 2000 pounds",
                    "8 - Pounds",
                    "9 - Gallons",
                    "10 - Metric tons, 2204.6 pounds",
                    "11 - Brazilian real",
                    "12 - Troy ounces",
                    "13 - British pounds",
                    "14 - Euros",
                    "15 - Mexican peso",
                    "16 - Czech koruna",
                    "17 - Polish zloty",
                    "18 - Israeli shekel",
                    "19 - Barrels",
                    "20 - Metric ton",
                    "21 - Australian dollar",
                    "22 - New Zealand dollar",
                    "23 - Canadian dollar",
                    "24 - Swiss franc",
                    "25 - Japanese yen",
                    "26 - South African rand",
                    "27 - Hungarian forint",
                    "28 - Korean won",
                    "29 - Million British thermal units",
                    "30 - Chinese renminbi",
                    "31 - Megawatt hours",
                    "41 - Megawatt",
                    "42 - Therms",
                    "51 - Environmental offset",
                    "52 - Basis points",
                    "53 - Metric tons (thousands)",
                    "54 - Gross tons",
                    "55 - Tons (thousands)",
                    "56 - Ton",
                    "57 - Bitcoin",
                    "58 - Russian ruble",
                    "59 - Indian rupee",
                    "60 - 1 day of time charter",
                    "61 - Cubic meter",
                    "62 - Kiloliters",
                    "63 - Kilos",
                    "64 - Chilean peso",
                    "65 - Regional Greenhouse Gas Initiative allowances (RGGI)",
                    "66 - Hundredweight, 100 pounds",
                    "67 - Norwegian krone",
                    "68 - Allowance (emission)",
                    "69 - Board feet",
                    "70 - Grams",
                    "71 - Swedish krona",
                    "72 - Environmental credit",
                    "73 - Dry metric tons",
                    "74 - Shares",
                    "75 - Metric ton",
                    "76 - Malaysian ringgit",
                    "77 - Ether",
                    "78 - Pounds net weight",
                    "79 - Renewable Identification Number (RIN)",
                    "80 - Barrels (thousands)",
                    "81 - Troy ounce (millions)"
                  ]
                },
                "min_tick": {
                  "type": "string",
                  "description": "Minimum price increment (tick size) for the futures price. ",
                  "example": "0.25"
                },
                "first_notice_date": {
                  "type": "string",
                  "description": "First notice date. For physically delivered contracts, this is the first date on which physical delivery can be assigned. After this date, new long positions cannot be opened, and existing long positions are typically forced to close a few trading days before this date. For cash-settled or index futures, this field is usually empty.",
                  "example": "2025-11-25"
                },
                "last_notice_date": {
                  "type": "string",
                  "description": "Last notice date, i.e. the last date on which the buyer can be notified to take physical delivery.",
                  "example": "2025-11-28"
                },
                "first_trading_date": {
                  "type": "string",
                  "description": "First trading date on which this futures contract becomes tradable.",
                  "example": "2024-12-01"
                },
                "last_trading_date": {
                  "type": "string",
                  "description": "Last trading date, i.e. the final trading day in the delivery month. After this date, any outstanding futures positions must be closed out through physical delivery or cash settlement. For cash-settled contracts, trading is allowed normally before the last trading deadline. For non-cash-settled contracts, opening new positions is usually restricted from three trading days before the earlier of the last trading date or first notice date.",
                  "example": "2025-12-19"
                },
                "contract_type": {
                  "type": "string",
                  "description": "Contract type. MONTHLY means regular month contract; MAIN means main/continuous contract.",
                  "example": "MONTHLY",
                  "enum": [
                    "MONTHLY",
                    "MAIN"
                  ]
                },
                "settlement": {
                  "type": "string",
                  "description": "Settlement method of the contract. Cash means cash settlement; Physical means physical delivery. ",
                  "example": "Cash",
                  "enum": [
                    "Cash",
                    "Physical"
                  ]
                }
              },
              "description": "Futures instrument profile information",
              "title": "FuturesInstrumentVo"
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
    "name": "List Futures Contracts",
    "description": {
      "content": "Retrieves profile information for one or multiple futures trading instruments by symbol(s).",
      "type": "text/plain"
    },
    "url": {
      "path": [
        "trading",
        "instruments",
        "futures",
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
            "content": "(Required) Security type. Fixed value: US_FUTURES.",
            "type": "text/plain"
          },
          "key": "category",
          "value": ""
        },
        {
          "disabled": false,
          "description": {
            "content": "List of futures trading symbols. Accepts JSON array format or comma-separated strings. Maximum of 100 symbols per request. Note: Either symbols or code must be provided. ",
            "type": "text/plain"
          },
          "key": "symbols",
          "value": ""
        },
        {
          "disabled": false,
          "description": {
            "content": "List of futures trading code, remark:Either 'symbols' or 'code' must be present.",
            "type": "text/plain"
          },
          "key": "code",
          "value": ""
        },
        {
          "disabled": false,
          "description": {
            "content": "Tradable Status<br/>OC - Tradable: Security is available for trading<br/>CO - Liquidate only: Security can only be sold, no purchases allowed<br/>NT - Non-Tradable: Security cannot be traded<br/>Default: OC",
            "type": "text/plain"
          },
          "key": "status",
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
