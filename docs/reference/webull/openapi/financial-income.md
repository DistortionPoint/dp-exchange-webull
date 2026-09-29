# Get Income Statement

• Function description: Get income statement data for a stock.<br/>• Frequency limit: Rate limit 60 requests every 60 seconds

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
  "path": "/market-data/fundamentals/income-statements/get",
  "method": "get",
  "tags": [
    "Fundamentals"
  ],
  "description": "• Function description: Get income statement data for a stock.<br/>• Frequency limit: Rate limit 60 requests every 60 seconds",
  "operationId": "financialIncome",
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
                  "example": "2025-09-27"
                },
                "currency": {
                  "type": "string",
                  "description": "Currency",
                  "example": "USD"
                },
                "publish_date": {
                  "type": "string",
                  "description": "Publish date",
                  "example": "2025-10-30"
                },
                "total_revenue": {
                  "type": "string",
                  "description": "Total revenue",
                  "example": "416161000000"
                },
                "revenue": {
                  "type": "string",
                  "description": "Revenue",
                  "example": "416161000000"
                },
                "cost_of_revenue": {
                  "type": "string",
                  "description": "Total cost of revenue",
                  "example": "220960000000"
                },
                "gross_profit": {
                  "type": "string",
                  "description": "Gross profit",
                  "example": "195201000000"
                },
                "opex": {
                  "type": "string",
                  "description": "Operating expenses",
                  "example": "62151000000"
                },
                "sga_exp": {
                  "type": "string",
                  "description": "Selling, general and administrative expenses",
                  "example": "27601000000"
                },
                "rnd_exp": {
                  "type": "string",
                  "description": "Research and development expenses",
                  "example": "34550000000"
                },
                "op_income": {
                  "type": "string",
                  "description": "Operating income",
                  "example": "133050000000"
                },
                "other_net_income": {
                  "type": "string",
                  "description": "Other net income",
                  "example": "-321000000"
                },
                "ebt": {
                  "type": "string",
                  "description": "Net income before tax",
                  "example": "132729000000"
                },
                "income_tax": {
                  "type": "string",
                  "description": "Income tax",
                  "example": "21205000000"
                },
                "eat": {
                  "type": "string",
                  "description": "Net income after tax",
                  "example": "111524000000"
                },
                "ni_pre_extra": {
                  "type": "string",
                  "description": "Net income before extraordinary items",
                  "example": "111524000000"
                },
                "extra_items": {
                  "type": "string",
                  "description": "Total extraordinary items",
                  "example": "486000000"
                },
                "net_income": {
                  "type": "string",
                  "description": "Net income",
                  "example": "112010000000"
                },
                "ni_common_excl_extra": {
                  "type": "string",
                  "description": "Income available to common shareholders excluding extraordinary items",
                  "example": "111524000000"
                },
                "ni_common_incl_extra": {
                  "type": "string",
                  "description": "Income available to common shareholders including extraordinary items",
                  "example": "112010000000"
                },
                "diluted_ni": {
                  "type": "string",
                  "description": "Diluted net income",
                  "example": "112010000000"
                },
                "diluted_avg_shares": {
                  "type": "string",
                  "description": "Diluted weighted average shares",
                  "example": "15004697000"
                },
                "diluted_eps_excl_extra": {
                  "type": "string",
                  "description": "Diluted EPS excluding extraordinary items",
                  "example": "7.43261"
                },
                "diluted_eps_incl_extra": {
                  "type": "string",
                  "description": "Diluted EPS including extraordinary items",
                  "example": "7.464996"
                },
                "dps": {
                  "type": "string",
                  "description": "Dividends per share",
                  "example": "1.02"
                },
                "diluted_norm_eps": {
                  "type": "string",
                  "description": "Diluted normalized EPS",
                  "example": "7.43261"
                },
                "op_profit": {
                  "type": "string",
                  "description": "Operating profit",
                  "example": "133050000000"
                },
                "eat_alt": {
                  "type": "string",
                  "description": "Earnings after tax",
                  "example": "111524000000"
                },
                "ebt_alt": {
                  "type": "string",
                  "description": "Earnings before tax",
                  "example": "132729000000"
                },
                "unusual_expense_income": {
                  "type": "string",
                  "description": "Non-recurring expenses (income)",
                  "example": "151341000000"
                },
                "inter_inc_expse_net_non_oper": {
                  "type": "string",
                  "description": "Net interest expense (income), non-operating",
                  "example": "151341000000"
                },
                "gain_loss_on_sale_of_assets": {
                  "type": "string",
                  "description": "Gain (Loss) from Asset Sale",
                  "example": "151341000000"
                },
                "minority_interest": {
                  "type": "string",
                  "description": "Minority shareholders' equity",
                  "example": "151341000000"
                }
              },
              "description": "Income Statement",
              "title": "IncomeStatementVo"
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
    "name": "Get Income Statement",
    "description": {
      "content": "• Function description: Get income statement data for a stock.<br/>• Frequency limit: Rate limit 60 requests every 60 seconds",
      "type": "text/plain"
    },
    "url": {
      "path": [
        "market-data",
        "fundamentals",
        "income-statements",
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
