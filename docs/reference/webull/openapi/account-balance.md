# Get Account Balance

Retrieves account details by account ID.

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
  "path": "/trading/assets/balances/get",
  "method": "get",
  "tags": [
    "Assets"
  ],
  "description": "Retrieves account details by account ID.",
  "operationId": "accountBalance",
  "parameters": [
    {
      "name": "account_id",
      "in": "query",
      "description": "Account identifier",
      "required": true,
      "schema": {
        "type": "String"
      },
      "example": "LOJOQITOD49R6G9BPQM489CISA"
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
            "required": [
              "account_currency_assets",
              "total_asset_currency",
              "total_cash_balance",
              "total_day_profit_loss",
              "total_market_value",
              "total_net_liquidation_value",
              "total_unrealized_profit_loss"
            ],
            "type": "object",
            "properties": {
              "total_asset_currency": {
                "type": "string",
                "description": "Currency",
                "example": "USD",
                "enum": [
                  "USD"
                ]
              },
              "total_cash_balance": {
                "type": "string",
                "description": "Cash Balance, When the account class is EVENTS_CASH, the data is empty.",
                "example": "485705.0"
              },
              "total_market_value": {
                "type": "string",
                "description": "Total holding market value",
                "example": "995705.0"
              },
              "total_unrealized_profit_loss": {
                "type": "string",
                "description": "Open P&L",
                "example": "227689.0"
              },
              "total_net_liquidation_value": {
                "type": "string",
                "description": "Net Account Value，When the account class is EVENTS_CASH, the data is empty.",
                "example": "727687.04"
              },
              "total_day_profit_loss": {
                "type": "string",
                "description": "Day's P&L",
                "example": "11798.6"
              },
              "day_trades_left": {
                "type": "string",
                "description": "Day Trades Left, When the account class is EVENTS_CASH, the data is empty.<br/> There are limits: numbers. <br/>No limit: UNLIMITED",
                "example": "UNLIMITED",
                "deprecated": true
              },
              "maintenance_margin": {
                "type": "string",
                "description": "Maintenance Margin（Margin Account）",
                "example": "0.0"
              },
              "open_margin_calls": {
                "type": "string",
                "description": "Open Margin Calls",
                "example": "['EM']",
                "enum": [
                  "EM",
                  "RM",
                  "RT",
                  "DT"
                ]
              },
              "used_margin": {
                "type": "string",
                "description": "Margin currently consumed by open positions",
                "example": "0.0"
              },
              "used_margin_for_open_order": {
                "type": "string",
                "description": "Margin reserved for pending/working orders; not available for other use",
                "example": "0.0"
              },
              "init_margin": {
                "type": "string",
                "description": "Total initial margin requirement for the current open positions at entry",
                "example": "2223650.0"
              },
              "intraday_margin": {
                "type": "string",
                "description": "Intraday margin requirement for current positions; typically lower than overnight initial margin",
                "example": "2223650.0"
              },
              "margin_excess": {
                "type": "string",
                "description": "Remaining available margin after accounting for required margins",
                "example": "2.32435219E8"
              },
              "margin_ratio": {
                "type": "string",
                "description": "The Equity to Margin Ratio  (aka Margin Ratio) is a risk-capacity metric that quantifies the proportion(0%–100%) of an account's total capital allocated to cover initial margin requirements ; lower values indicate a higher likelihood of margin stress or forced liquidation",
                "example": "1.0"
              },
              "account_currency_assets": {
                "type": "array",
                "description": "Currency assets Details",
                "items": {
                  "required": [
                    "cash_balance",
                    "currency",
                    "market_value",
                    "unrealized_profit_loss"
                  ],
                  "type": "object",
                  "properties": {
                    "currency": {
                      "type": "string",
                      "description": "Currency",
                      "example": "USD",
                      "enum": [
                        "USD"
                      ]
                    },
                    "cash_balance": {
                      "type": "string",
                      "description": "Cash Balance，When the account class is EVENTS_CASH, the data is empty.",
                      "example": "485705.95"
                    },
                    "settled_cash": {
                      "type": "string",
                      "description": "Settled Cash，When the account class is EVENTS_CASH, the data is empty.",
                      "example": "485705.95"
                    },
                    "unsettled_cash": {
                      "type": "string",
                      "description": "Unsettled Cash，When the account class is EVENTS_CASH, the data is empty.",
                      "example": "0.0"
                    },
                    "market_value": {
                      "type": "string",
                      "description": "holding market value",
                      "example": "0.0"
                    },
                    "held_amount": {
                      "type": "string",
                      "description": "In-transit funds",
                      "example": "0.0"
                    },
                    "frozen_amount": {
                      "type": "string",
                      "description": "Frozen funds",
                      "example": "485705"
                    },
                    "buying_power": {
                      "type": "string",
                      "description": "Buying Power",
                      "example": "484551"
                    },
                    "unrealized_profit_loss": {
                      "type": "string",
                      "description": "Open P&L",
                      "example": "227689"
                    },
                    "available_withdrawal": {
                      "type": "string",
                      "description": "The withdrawable amount",
                      "example": "3.0558743194E8"
                    },
                    "interests_unpaid": {
                      "type": "string",
                      "description": "Interest to be paid",
                      "example": "0.0"
                    },
                    "net_liquidation_value": {
                      "type": "string",
                      "description": "Net Account Value",
                      "example": "0.0"
                    },
                    "option_buying_power": {
                      "type": "string",
                      "description": "Options Buying Power",
                      "example": "0.0"
                    },
                    "day_buying_power": {
                      "type": "string",
                      "description": "Day-Trade Buying Power（Margin Account）",
                      "example": "0.0"
                    },
                    "overnight_buying_power": {
                      "type": "string",
                      "description": "Overnight BP（Margin Account）",
                      "example": "0.0"
                    },
                    "night_trading_buying_power": {
                      "type": "string",
                      "description": "Night Trading Buying Power",
                      "example": "0.0"
                    },
                    "day_profit_loss": {
                      "type": "string",
                      "description": "Day's P&L",
                      "example": "0.0"
                    },
                    "used_margin": {
                      "type": "string",
                      "description": "Margin currently consumed by open positions",
                      "example": "0.0"
                    },
                    "used_margin_for_open_order": {
                      "type": "string",
                      "description": "Margin reserved for pending/working orders; not available for other use",
                      "example": "0.0"
                    },
                    "init_margin": {
                      "type": "string",
                      "description": "Total initial margin requirement for the current open positions at entry",
                      "example": "2223650.0"
                    },
                    "maintenance_margin": {
                      "type": "string",
                      "description": "Minimum margin required to maintain current positions; falling below this may trigger a margin call",
                      "example": "0.0"
                    },
                    "intraday_margin": {
                      "type": "string",
                      "description": "Intraday margin requirement for current positions; typically lower than overnight initial margin",
                      "example": "2223650.0"
                    },
                    "margin_excess": {
                      "type": "string",
                      "description": "Remaining available margin after accounting for required margins",
                      "example": "2.32435219E8"
                    },
                    "margin_ratio": {
                      "type": "string",
                      "description": "The Equity to Margin Ratio  (aka Margin Ratio) is a risk-capacity metric that quantifies the proportion(0%–100%) of an account's total capital allocated to cover initial margin requirements ; lower values indicate a higher likelihood of margin stress or forced liquidation",
                      "example": "1.0"
                    }
                  },
                  "description": "Currency assets Details",
                  "title": "AssetsCurrencyAssets"
                }
              }
            },
            "title": "AssetsBalanceResult"
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
    "name": "Get Account Balance",
    "description": {
      "content": "Retrieves account details by account ID.",
      "type": "text/plain"
    },
    "url": {
      "path": [
        "trading",
        "assets",
        "balances",
        "get"
      ],
      "host": [
        "{{baseUrl}}"
      ],
      "query": [
        {
          "disabled": false,
          "description": {
            "content": "(Required) Account identifier",
            "type": "text/plain"
          },
          "key": "account_id",
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
