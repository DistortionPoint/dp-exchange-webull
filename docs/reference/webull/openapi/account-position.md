# List Account Positions

Retrieves positions according to the account ID

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
  "path": "/trading/assets/positions/list",
  "method": "get",
  "tags": [
    "Assets"
  ],
  "description": "Retrieves positions according to the account ID",
  "operationId": "accountPosition",
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
            "type": "array",
            "items": {
              "required": [
                "cost_price",
                "currency",
                "instrument_type",
                "last_price",
                "option_strategy",
                "position_id",
                "quantity",
                "symbol",
                "unrealized_profit_loss"
              ],
              "type": "object",
              "properties": {
                "position_id": {
                  "type": "string",
                  "description": "Position ID",
                  "example": "N4I4SIM8TJF38KN2TAA0QVVNE9"
                },
                "currency": {
                  "type": "string",
                  "description": "Currency",
                  "example": "USD",
                  "enum": [
                    "USD"
                  ]
                },
                "quantity": {
                  "type": "string",
                  "description": "Quantity of the position",
                  "example": "1"
                },
                "symbol": {
                  "type": "string",
                  "description": "Trading symbol of the financial instrument.Represents the unique identifier of the security in the specified market (e.g., ticker symbol for equities or option symbol code for derivatives).",
                  "example": "AAPL"
                },
                "option_strategy": {
                  "type": "string",
                  "description": "Type of options strategy<br/> Possible values:<br/> &bull; SINGLE<br/> &bull; COVERED_STOCK<br/> &bull; STRADDLE<br/> &bull; STRANGLE<br/> &bull; VERTICAL<br/> &bull; CALENDAR<br/> &bull; BUTTERFLY<br/> &bull; CONDOR<br/> &bull; COLLAR_WITH_STOCK<br/> &bull; IRON_BUTTERFLY<br/> &bull; IRON_CONDOR<br/> &bull; DIAGONAL<br/> Note: When option_strategy is set to a multi-leg strategy (any value other than SINGLE), combo_type only supports NORMAL. The MASTER, STOP_PROFIT and STOP_LOSS combo types are only supported when option_strategy = SINGLE.<br/> Note: OTO, OCO and OTOCO combo types are only supported for stock (EQUITY) orders and are not supported for option orders regardless of option_strategy.",
                  "example": "SINGLE",
                  "enum": [
                    "SINGLE"
                  ]
                },
                "instrument_type": {
                  "type": "string",
                  "description": "Type of financial instrument associated with the request.",
                  "example": "OPTION",
                  "enum": [
                    "EQUITY",
                    "OPTION",
                    "FUTURES",
                    "CRYPTO",
                    "EVENT"
                  ]
                },
                "last_price": {
                  "type": "string",
                  "description": "Last Price",
                  "example": "10.0"
                },
                "cost_price": {
                  "type": "string",
                  "description": "Cost Basis",
                  "example": "11.12"
                },
                "unrealized_profit_loss": {
                  "type": "string",
                  "description": "Open P&L",
                  "example": "0.08"
                },
                "event_outcome": {
                  "type": "string",
                  "description": "Event outcome decision, only applicable to event orders.",
                  "example": "yes",
                  "enum": [
                    "yes",
                    "no"
                  ]
                },
                "legs": {
                  "type": "array",
                  "description": "legs",
                  "items": {
                    "required": [
                      "leg_id",
                      "symbol"
                    ],
                    "type": "object",
                    "properties": {
                      "leg_id": {
                        "type": "string",
                        "description": "Unique defined identifier for the leg.",
                        "example": "G2JAJPOR4KUA0F5I9LONH8J83A"
                      },
                      "symbol": {
                        "type": "string",
                        "description": "Trading symbol of the financial instrument.Represents the unique identifier of the security in the specified market (e.g., ticker symbol for equities or option symbol code for derivatives).",
                        "example": "AAPL"
                      },
                      "quantity": {
                        "type": "string",
                        "description": "The number of stocks currently available for trading",
                        "example": "4"
                      },
                      "option_type": {
                        "type": "string",
                        "description": "Type of the option. <br/> &bull; CALL: Right to buy the underlying asset. <br/> &bull; PUT: Right to sell the underlying asset.",
                        "example": "CALL",
                        "enum": [
                          "CALL",
                          "PUT"
                        ]
                      },
                      "option_expire_date": {
                        "type": "string",
                        "description": "Option expiration date. Format: yyyy-MM-dd",
                        "example": "2019-09-20"
                      },
                      "option_exercise_price": {
                        "type": "string",
                        "description": "Exercise Price",
                        "example": "11.0"
                      },
                      "option_contract_multiplier": {
                        "type": "string",
                        "description": "The number of shares corresponding to each option contract",
                        "example": "100"
                      },
                      "option_contract_deliverable": {
                        "type": "string",
                        "description": "The number of shares required to exercise each contract",
                        "example": "100"
                      },
                      "expiration_type": {
                        "type": "string",
                        "description": "Option Expiration Types",
                        "example": "AM"
                      }
                    },
                    "description": "legs",
                    "title": "PositionItem"
                  }
                }
              },
              "title": "AssetsPositionResult"
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
    "name": "List Account Positions",
    "description": {
      "content": "Retrieves positions according to the account ID",
      "type": "text/plain"
    },
    "url": {
      "path": [
        "trading",
        "assets",
        "positions",
        "list"
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
