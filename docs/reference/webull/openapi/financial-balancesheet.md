# Get Balance Sheet

• Function description: Get balance sheet data for a stock.<br/>• Frequency limit: Rate limit 60 requests every 60 seconds

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
  "path": "/market-data/fundamentals/balance-sheets/get",
  "method": "get",
  "tags": [
    "Fundamentals"
  ],
  "description": "• Function description: Get balance sheet data for a stock.<br/>• Frequency limit: Rate limit 60 requests every 60 seconds",
  "operationId": "financialBalancesheet",
  "parameters": [
    {
      "name": "symbol",
      "in": "query",
      "description": "Security symbol.",
      "required": true,
      "schema": {
        "type": "string"
      },
      "example": "TSLA"
    },
    {
      "name": "category",
      "in": "query",
      "description": "Security type. Currently only US_STOCK is supported.",
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
      "name": "type",
      "in": "query",
      "description": "Financial type: ANNUAL or QUARTERLY.",
      "required": false,
      "schema": {
        "type": "string",
        "default": "QUARTERLY"
      },
      "example": "QUARTERLY"
    },
    {
      "name": "count",
      "in": "query",
      "description": "The number of each query, default value is 5, maximum value is 20.",
      "required": false,
      "schema": {
        "type": "string",
        "default": "5"
      },
      "example": 5
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
                "fiscal_year": {
                  "type": "integer",
                  "description": "Fiscal year",
                  "format": "int32",
                  "example": 2026
                },
                "fiscal_period": {
                  "type": "integer",
                  "description": "Fiscal period (0=FY, 1=Q1, 2=Q2, 3=Q3, 4=Q4)",
                  "format": "int32",
                  "example": 0
                },
                "end_date": {
                  "type": "string",
                  "description": "Report end date",
                  "example": "2025-12-27"
                },
                "currency": {
                  "type": "string",
                  "description": "Currency",
                  "example": "USD"
                },
                "publish_date": {
                  "type": "string",
                  "description": "Publish date",
                  "example": "2026-01-30"
                },
                "total_assets": {
                  "type": "string",
                  "description": "Total assets",
                  "example": "379297000000"
                },
                "total_cur_assets": {
                  "type": "string",
                  "description": "Total current assets",
                  "example": "158104000000"
                },
                "cash_st_invest": {
                  "type": "string",
                  "description": "Cash and short-term investments",
                  "example": "66907000000"
                },
                "cash": {
                  "type": "string",
                  "description": "Cash",
                  "example": "30826000000"
                },
                "cash_equiv": {
                  "type": "string",
                  "description": "Cash equivalents",
                  "example": "14491000000"
                },
                "st_invest": {
                  "type": "string",
                  "description": "Short-term investments",
                  "example": "21590000000"
                },
                "total_recv_net": {
                  "type": "string",
                  "description": "Total receivables (net)",
                  "example": "70320000000"
                },
                "ar_trade_net": {
                  "type": "string",
                  "description": "Trade receivables (net)",
                  "example": "39921000000"
                },
                "total_inv": {
                  "type": "string",
                  "description": "Total inventory",
                  "example": "5875000000"
                },
                "other_cur_assets": {
                  "type": "string",
                  "description": "Other current assets",
                  "example": "15002000000"
                },
                "total_non_cur_assets": {
                  "type": "string",
                  "description": "Total non-current assets",
                  "example": "221193000000"
                },
                "ppe_net": {
                  "type": "string",
                  "description": "Property, plant and equipment (net)",
                  "example": "50159000000"
                },
                "ppe_gross": {
                  "type": "string",
                  "description": "Property, plant and equipment (gross)",
                  "example": "127320000000"
                },
                "acc_depre": {
                  "type": "string",
                  "description": "Accumulated depreciation",
                  "example": "77161000000"
                },
                "lt_invest": {
                  "type": "string",
                  "description": "Long-term investments",
                  "example": "77888000000"
                },
                "other_lt_assets": {
                  "type": "string",
                  "description": "Other long-term assets",
                  "example": "93146000000"
                },
                "total_liab": {
                  "type": "string",
                  "description": "Total liabilities",
                  "example": "291107000000"
                },
                "total_cur_liab": {
                  "type": "string",
                  "description": "Total current liabilities",
                  "example": "162367000000"
                },
                "ap": {
                  "type": "string",
                  "description": "Accounts payable",
                  "example": "70587000000"
                },
                "notes_st_debt": {
                  "type": "string",
                  "description": "Short-term debt",
                  "example": "1997000000"
                },
                "cur_lt_debt_lease": {
                  "type": "string",
                  "description": "Current portion of long-term debt",
                  "example": "11827000000"
                },
                "other_cur_liab": {
                  "type": "string",
                  "description": "Other current liabilities",
                  "example": "77956000000"
                },
                "total_non_cur_liab": {
                  "type": "string",
                  "description": "Total non-current liabilities",
                  "example": "128740000000"
                },
                "total_lt_debt": {
                  "type": "string",
                  "description": "Total long-term debt",
                  "example": "76685000000"
                },
                "lt_debt": {
                  "type": "string",
                  "description": "Long-term debt",
                  "example": "76685000000"
                },
                "total_debt": {
                  "type": "string",
                  "description": "Total debt",
                  "example": "90509000000"
                },
                "other_liab": {
                  "type": "string",
                  "description": "Other liabilities",
                  "example": "52055000000"
                },
                "total_equity": {
                  "type": "string",
                  "description": "Total equity",
                  "example": "88190000000"
                },
                "total_sh_equity": {
                  "type": "string",
                  "description": "Total shareholders' equity",
                  "example": "88190000000"
                },
                "common_stock": {
                  "type": "string",
                  "description": "Common stock",
                  "example": "147030"
                },
                "apic": {
                  "type": "string",
                  "description": "Additional paid-in capital",
                  "example": "95220852970"
                },
                "retained_earnings": {
                  "type": "string",
                  "description": "Retained earnings",
                  "example": "-2177000000"
                },
                "other_equity": {
                  "type": "string",
                  "description": "Other equity",
                  "example": "-4854000000"
                },
                "total_liab_sh_equity": {
                  "type": "string",
                  "description": "Total liabilities and shareholders' equity",
                  "example": "379297000000"
                },
                "common_shares_out": {
                  "type": "string",
                  "description": "Total common shares outstanding",
                  "example": "14702703000"
                },
                "prepaid_expenses": {
                  "type": "string",
                  "description": "Advance payment for expenses",
                  "example": "5000000"
                },
                "accrued_expenses": {
                  "type": "string",
                  "description": "Accrued expenses",
                  "example": "12000000"
                },
                "goodwill_net": {
                  "type": "string",
                  "description": "Net goodwill value",
                  "example": "25000000000"
                },
                "intangibles_net": {
                  "type": "string",
                  "description": "Net value of intangible assets",
                  "example": "8000000000"
                },
                "note_rece_long_term": {
                  "type": "string",
                  "description": "Long-term receivable bills",
                  "example": "3000000"
                },
                "capital_lease_obligations": {
                  "type": "string",
                  "description": "Long-term debt in capital lease transactions",
                  "example": "15000000"
                },
                "minority_interest": {
                  "type": "string",
                  "description": "Minority shareholders' equity",
                  "example": "500000"
                },
                "non_redeemable_preferred_stock": {
                  "type": "string",
                  "description": "Non-redeemable preferred stocks in total",
                  "example": "0"
                }
              },
              "description": "Balance Sheet",
              "title": "BalanceSheetVo"
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
    "name": "Get Balance Sheet",
    "description": {
      "content": "• Function description: Get balance sheet data for a stock.<br/>• Frequency limit: Rate limit 60 requests every 60 seconds",
      "type": "text/plain"
    },
    "url": {
      "path": [
        "market-data",
        "fundamentals",
        "balance-sheets",
        "get"
      ],
      "host": [
        "{{baseUrl}}"
      ],
      "query": [
        {
          "disabled": false,
          "description": {
            "content": "(Required) Security symbol.",
            "type": "text/plain"
          },
          "key": "symbol",
          "value": ""
        },
        {
          "disabled": false,
          "description": {
            "content": "(Required) Security type. Currently only US_STOCK is supported.",
            "type": "text/plain"
          },
          "key": "category",
          "value": ""
        },
        {
          "disabled": false,
          "description": {
            "content": "Financial type: ANNUAL or QUARTERLY.",
            "type": "text/plain"
          },
          "key": "type",
          "value": ""
        },
        {
          "disabled": false,
          "description": {
            "content": "The number of each query, default value is 5, maximum value is 20.",
            "type": "text/plain"
          },
          "key": "count",
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
