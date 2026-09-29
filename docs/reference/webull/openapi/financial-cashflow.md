# Get Cash Flow Statement

• Function description: Get cash flow statement data for a stock.<br/>• Frequency limit: Rate limit 60 requests every 60 seconds

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
  "path": "/market-data/fundamentals/cash-flows/get",
  "method": "get",
  "tags": [
    "Fundamentals"
  ],
  "description": "• Function description: Get cash flow statement data for a stock.<br/>• Frequency limit: Rate limit 60 requests every 60 seconds",
  "operationId": "financialCashflow",
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
                  "example": 2025
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
                  "example": "2025-12-31"
                },
                "currency": {
                  "type": "string",
                  "description": "Currency",
                  "example": "USD"
                },
                "publish_date": {
                  "type": "string",
                  "description": "Publish date",
                  "example": "2026-01-29"
                },
                "cfo": {
                  "type": "string",
                  "description": "Cash from operating activities",
                  "example": "14747000000"
                },
                "net_income": {
                  "type": "string",
                  "description": "Net income",
                  "example": "3855000000"
                },
                "dna": {
                  "type": "string",
                  "description": "Depreciation and amortization",
                  "example": "6148000000"
                },
                "deferred_tax": {
                  "type": "string",
                  "description": "Deferred taxes",
                  "example": "123000000"
                },
                "non_cash_items": {
                  "type": "string",
                  "description": "Non-cash items",
                  "example": "3979000000"
                },
                "wc_change": {
                  "type": "string",
                  "description": "Changes in working capital",
                  "example": "642000000"
                },
                "cfi": {
                  "type": "string",
                  "description": "Cash from investing activities",
                  "example": "-15478000000"
                },
                "capex": {
                  "type": "string",
                  "description": "Capital expenditures",
                  "example": "-8527000000"
                },
                "other_cfi_items": {
                  "type": "string",
                  "description": "Other investing cash flow items",
                  "example": "-6951000000"
                },
                "cff": {
                  "type": "string",
                  "description": "Cash from financing activities",
                  "example": "1139000000"
                },
                "cff_items": {
                  "type": "string",
                  "description": "Financing cash flow items",
                  "example": "17000000"
                },
                "net_stock_iss_ret": {
                  "type": "string",
                  "description": "Net issuance or repurchase of stock",
                  "example": "1186000000"
                },
                "net_debt_iss_ret": {
                  "type": "string",
                  "description": "Net issuance or repayment of debt",
                  "example": "-64000000"
                },
                "fx_effects": {
                  "type": "string",
                  "description": "Foreign exchange effects on cash",
                  "example": "171000000"
                },
                "net_change_cash": {
                  "type": "string",
                  "description": "Net change in cash",
                  "example": "579000000"
                },
                "interest_paid": {
                  "type": "string",
                  "description": "Cash interest paid",
                  "example": "292000000"
                },
                "taxes_paid": {
                  "type": "string",
                  "description": "Cash taxes paid",
                  "example": "1232000000"
                }
              },
              "description": "Cash Flow Statement",
              "title": "CashFlowStatementVo"
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
    "name": "Get Cash Flow Statement",
    "description": {
      "content": "• Function description: Get cash flow statement data for a stock.<br/>• Frequency limit: Rate limit 60 requests every 60 seconds",
      "type": "text/plain"
    },
    "url": {
      "path": [
        "market-data",
        "fundamentals",
        "cash-flows",
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
