# List Cash Activities

Lists an account's cash activities, filterable by type and time range. Defaults to the last 7 days if no date is provided.

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
  "path": "/trading/activities/cash-activities/list",
  "method": "get",
  "tags": [
    "Activities"
  ],
  "description": "Lists an account's cash activities, filterable by type and time range. Defaults to the last 7 days if no date is provided.",
  "operationId": "tradeCashActivityByType",
  "parameters": [
    {
      "name": "account_id",
      "in": "query",
      "description": "Provide the target account id",
      "required": true,
      "schema": {
        "type": "String"
      },
      "example": "943a9802f6c14983b3b4755c69c01717"
    },
    {
      "name": "activity_types",
      "in": "query",
      "description": "Account activity types.<br/>Note: EC_STATEMENT is deprecated; use EC_SETTLEMENT instead (EC_STATEMENT behaves the same as EC_SETTLEMENT).<br/>Note: Crypto accounts only support: TRADE, DEPOSIT, WITHDRAW, and FEES.\n",
      "required": false,
      "schema": {
        "type": "string",
        "enum": [
          "TRADE",
          "DEPOSIT",
          "WITHDRAW",
          "FEES",
          "TRANSFER",
          "DIVIDENDS",
          "TAX",
          "INTERESTS",
          "CORPORATE_ACTION",
          "OPTION_EA",
          "EC_SETTLEMENT",
          "JOURNAL"
        ]
      },
      "example": "DEPOSIT,TRADE"
    },
    {
      "name": "start_time",
      "in": "query",
      "description": "Activity query start time, time in ISO8601 format (UTC). Format: yyyy-MM-dd'T'HH:mm:ss.SSS'Z'. Cross-year queries are not supported; start_time and end_time must be within the same year.",
      "required": false,
      "schema": {
        "type": "String"
      },
      "example": "2025-01-05T22:59:59.012Z"
    },
    {
      "name": "end_time",
      "in": "query",
      "description": "If not provided, the default query is the last 7 days.<br/>Activity query end time, time in ISO8601 format (UTC). Format: yyyy-MM-dd'T'HH:mm:ss.SSS'Z'. Cross-year queries are not supported; start_time and end_time must be within the same year.",
      "required": false,
      "schema": {
        "type": "String"
      },
      "example": "2025-01-06T22:59:59.012Z"
    },
    {
      "name": "pagination_key",
      "in": "query",
      "description": "Pagination key from previous response for next page.",
      "required": false,
      "schema": {
        "type": "String"
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
                  "required": [
                    "account_id",
                    "activity_sub_type",
                    "activity_type",
                    "biz_time",
                    "currency",
                    "id",
                    "net_amount",
                    "trade_date"
                  ],
                  "type": "object",
                  "properties": {
                    "id": {
                      "type": "string",
                      "description": "Unique ID",
                      "example": "a1b2c3d4e5f6g7h8i9j0"
                    },
                    "account_id": {
                      "type": "string",
                      "description": "Account ID",
                      "example": "943a9802f6c14983b3b4755c69c01717"
                    },
                    "activity_type": {
                      "type": "string",
                      "description": "Activity Type\n| Code             | Description                          |\n|------------------|--------------------------------------|\n| TRADE            | Trade Activity Type                  |\n| DEPOSIT          | Deposit Activity Type                |\n| WITHDRAW         | Withdraw Activity Type               |\n| FEES             | Fees Activity Type                   |\n| TRANSFER         | Transfer Activity Type               |\n| DIVIDENDS        | Dividends Activity Type              |\n| TAX              | Tax Activity Type                    |\n| INTERESTS        | Interests Activity Type              |\n| CORPORATE_ACTION | Corporate Action Activity Type       |\n| OPTION_EA        | Option Exercise and Assignment Type  |\n| JOURNAL          | Journal Activity Type                |\n| EC_SETTLEMENT    | EC Settlement Activity Type          |\n| OTHER            | Other Activity Type                  |",
                      "example": "TRADE",
                      "enum": [
                        "TRADE",
                        "DEPOSIT",
                        "WITHDRAW",
                        "FEES",
                        "TRANSFER",
                        "DIVIDENDS",
                        "TAX",
                        "INTERESTS",
                        "CORPORATE_ACTION",
                        "OPTION_EA",
                        "JOURNAL",
                        "EC_SETTLEMENT",
                        "OTHER"
                      ]
                    },
                    "activity_sub_type": {
                      "type": "string",
                      "description": "Activity Type and Sub Type Mapping.\n| ActivityType     | ActivitySubType            |\n|------------------|---------------------------|\n| TRADE            | BUY                       |\n| TRADE            | SELL                      |\n| TRADE            | BUY_CANCELLED             |\n| TRADE            | SELL_CANCELLED            |\n| TRADE            | PENNY_FOR_LOT             |\n| TRADE            | FX_EXCHANGE               |\n| DEPOSIT          | WIRE                      |\n| DEPOSIT          | ACH                       |\n| DEPOSIT          | REVERSAL                  |\n| DEPOSIT          | CHECK                     |\n| DEPOSIT          | ACH_REVERSE                     |\n| DEPOSIT          | INTERNAL_TRANSFER                     |\n| WITHDRAW         | WIRE                      |\n| WITHDRAW         | ACH                       |\n| WITHDRAW         | REVERSAL                  |\n| WITHDRAW         | CHECK                     |\n| WITHDRAW         | INTERNAL_TRANSFER                     |\n| FEES             | WIRE_FEE                  |\n| FEES             | REVERSAL_FEE              |\n| FEES             | TRANSFER_ACATS            |\n| FEES             | CA_HANDLING_FEE           |\n| FEES             | ADR                       |\n| FEES             | PAPER_STATEMENT_FEE       |\n| FEES             | PAPER_CONFIRM_FEE         |\n| FEES             | WRITE_OFF                 |\n| FEES             | CHECK_FEE                 |\n| FEES             | ADVISORY_FEE              |\n| FEES             | SUBSCRIPTION_FEE          |\n| FEES             | SERVICE_FEE               |\n| FEES             | ACH_REVERSE_FEE               |\n| FEES             | OTHER                     |\n| TRANSFER         | ACATS_IN                  |\n| TRANSFER         | ACATS_OUT                 |\n| TRANSFER         | INTERNAL_TRANSFER         |\n| TRANSFER         | BANK_SWEEP                |\n| DIVIDENDS        | INCOME                    |\n| DIVIDENDS        | PAYMENT_IN_LIEU           |\n| DIVIDENDS        | CASH_IN_LIEU              |\n| DIVIDENDS        | LP_DISTRIBUTION           |\n| TAX              | FOREIGN_TAX_WITHHELD      |\n| TAX              | US_TAX_WITHHOLDING        |\n| TAX              | IRA_FED_WITHHOLDING       |\n| TAX              | STATE_WITHHOLDING         |\n| TAX              | WITHHOLDING_TAX           |\n| TAX              | GP_TAX_WITHHELD           |\n| TAX              | OTHER                     |\n| INTERESTS        | CREDIT                    |\n| INTERESTS        | DEBIT                     |\n| INTERESTS        | STOCK_BORROW_INTEREST     |\n| INTERESTS        | SECURITIES_LENDING_INCOME |\n| INTERESTS        | ADJUSTMENT                |\n| INTERESTS        | PAYMENT                   |\n| INTERESTS        | INTEREST_REBATE           |\n| CORPORATE_ACTION | CASH_IN_LIEU              |\n| CORPORATE_ACTION | REDEMPTION                |\n| CORPORATE_ACTION | MISC_ADJUSTMENT           |\n| CORPORATE_ACTION | MERGER                    |\n| CORPORATE_ACTION | RIGHTS_OFFERING           |\n| CORPORATE_ACTION | IDENTIFIER_CHANGE         |\n| CORPORATE_ACTION | REVERSE_SPLIT             |\n| CORPORATE_ACTION | FORWARD_SPLIT             |\n| CORPORATE_ACTION | SPIN_OFF                  |\n| CORPORATE_ACTION | CONVERSION                |\n| CORPORATE_ACTION | LIQUIDATION               |\n| OPTION_EA        | CONTRACT_CLOSE            |\n| OPTION_EA        | OPTION_ASSIGNMENT         |\n| OPTION_EA        | OPTION_EXPIRATION         |\n| OPTION_EA        | OPTION_EXERCISE           |\n| JOURNAL          | CASH_JOURNAL              |\n| EC_SETTLEMENT    | EC_EXPIRATION             |\n| EC_SETTLEMENT    | EC_PAYOUT                 |\n| OTHER            | INCOME                    |\n| OTHER            | LENDING_REBATE            |\n| OTHER            | DVP                       |\n| OTHER            | GRID_TRANSFER                       |\n| OTHER            | OTHER                     |",
                      "example": "BUY",
                      "enum": [
                        "BUY",
                        "SELL",
                        "BUY_CANCELLED",
                        "SELL_CANCELLED",
                        "PENNY_FOR_LOT",
                        "TRADE",
                        "FX_EXCHANGE",
                        "OPTION_EXPIRATION",
                        "WIRE",
                        "ACH",
                        "REVERSAL",
                        "CHECK",
                        "ACH_REVERSE",
                        "WIRE_FEE",
                        "REVERSAL_FEE",
                        "TRANSFER_ACATS",
                        "CA_HANDLING_FEE",
                        "ADR",
                        "PAPER_STATEMENT_FEE",
                        "PAPER_CONFIRM_FEE",
                        "WRITE_OFF",
                        "CHECK_FEE",
                        "ADVISORY_FEE",
                        "SUBSCRIPTION_FEE",
                        "SERVICE_FEE",
                        "ACH_REVERSE_FEE",
                        "ACATS_IN",
                        "ACATS_OUT",
                        "INTERNAL_TRANSFER",
                        "BANK_SWEEP",
                        "INCOME",
                        "PAYMENT_IN_LIEU",
                        "CASH_IN_LIEU",
                        "LP_DISTRIBUTION",
                        "FOREIGN_TAX_WITHHELD",
                        "US_TAX_WITHHOLDING",
                        "IRA_FED_WITHHOLDING",
                        "STATE_WITHHOLDING",
                        "WITHHOLDING_TAX",
                        "GP_TAX_WITHHELD",
                        "CREDIT",
                        "DEBIT",
                        "STOCK_BORROW_INTEREST",
                        "SECURITIES_LENDING_INCOME",
                        "ADJUSTMENT",
                        "PAYMENT",
                        "INTEREST_REBATE",
                        "REDEMPTION",
                        "MISC_ADJUSTMENT",
                        "MERGER",
                        "RIGHTS_OFFERING",
                        "IDENTIFIER_CHANGE",
                        "REVERSE_SPLIT",
                        "FORWARD_SPLIT",
                        "SPIN_OFF",
                        "CONVERSION",
                        "LIQUIDATION",
                        "CONTRACT_CLOSE",
                        "OPTION_ASSIGNMENT",
                        "OPTION_EXERCISE",
                        "CASH_JOURNAL",
                        "EC_EXPIRATION",
                        "EC_PAYOUT",
                        "LENDING_REBATE",
                        "DVP",
                        "GRID_TRANSFER",
                        "OTHER"
                      ]
                    },
                    "currency": {
                      "type": "string",
                      "description": "Currency",
                      "example": "USD",
                      "enum": [
                        "USD"
                      ]
                    },
                    "market": {
                      "type": "string",
                      "description": "Market Code<br/>US - US Market<br/>",
                      "example": "US",
                      "enum": [
                        "US"
                      ]
                    },
                    "symbol": {
                      "type": "string",
                      "description": "Activity Symbol",
                      "example": "AAPL"
                    },
                    "trade_date": {
                      "type": "string",
                      "description": "Accounting date of the transaction (trade date), format: yyyy-MM-dd",
                      "example": "2024-05-01"
                    },
                    "net_amount": {
                      "type": "string",
                      "description": "Net change amount of the transaction (positive for credit, negative for debit)",
                      "example": "1500.0"
                    },
                    "biz_time": {
                      "type": "string",
                      "description": "Business event time when the transaction occurred",
                      "example": "2024-05-01T10:15:30.691Z"
                    }
                  },
                  "description": "Activity Cash Result",
                  "title": "ActivityCashResult"
                }
              },
              "pagination_key": {
                "type": "string",
                "description": "Pagination key for next page. If absent, indicates this is the last page.",
                "example": "eyJ2IjoxLCJsYXN0SWQiOiI5MTMyNDQ3NjkiLCJwYWdlSW===="
              }
            },
            "description": "Paginated result with cursor-based pagination",
            "title": "PaginatedResultVoActivityCashResult"
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
    "name": "List Cash Activities",
    "description": {
      "content": "Lists an account's cash activities, filterable by type and time range. Defaults to the last 7 days if no date is provided.",
      "type": "text/plain"
    },
    "url": {
      "path": [
        "trading",
        "activities",
        "cash-activities",
        "list"
      ],
      "host": [
        "{{baseUrl}}"
      ],
      "query": [
        {
          "disabled": false,
          "description": {
            "content": "(Required) Provide the target account id",
            "type": "text/plain"
          },
          "key": "account_id",
          "value": ""
        },
        {
          "disabled": false,
          "description": {
            "content": "Account activity types.<br/>Note: EC_STATEMENT is deprecated; use EC_SETTLEMENT instead (EC_STATEMENT behaves the same as EC_SETTLEMENT).<br/>Note: Crypto accounts only support: TRADE, DEPOSIT, WITHDRAW, and FEES.\n",
            "type": "text/plain"
          },
          "key": "activity_types",
          "value": ""
        },
        {
          "disabled": false,
          "description": {
            "content": "Activity query start time, time in ISO8601 format (UTC). Format: yyyy-MM-dd'T'HH:mm:ss.SSS'Z'. Cross-year queries are not supported; start_time and end_time must be within the same year.",
            "type": "text/plain"
          },
          "key": "start_time",
          "value": ""
        },
        {
          "disabled": false,
          "description": {
            "content": "If not provided, the default query is the last 7 days.<br/>Activity query end time, time in ISO8601 format (UTC). Format: yyyy-MM-dd'T'HH:mm:ss.SSS'Z'. Cross-year queries are not supported; start_time and end_time must be within the same year.",
            "type": "text/plain"
          },
          "key": "end_time",
          "value": ""
        },
        {
          "disabled": false,
          "description": {
            "content": "Pagination key from previous response for next page.",
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
