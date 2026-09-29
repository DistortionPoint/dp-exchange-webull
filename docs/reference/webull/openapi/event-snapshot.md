# List Event Snapshots

Retrieves a real-time snapshot for an event instrument.

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
  "path": "/market-data/event-contracts/snapshots/list",
  "method": "get",
  "tags": [
    "Event Market Data"
  ],
  "description": "Retrieves a real-time snapshot for an event instrument.",
  "operationId": "eventSnapshot",
  "parameters": [
    {
      "name": "symbols",
      "in": "query",
      "description": "Symbol of the event market, supports JSON array format, multiple symbols separated by commas; maximum 100 symbols per query.",
      "required": true,
      "schema": {
        "type": "string"
      },
      "example": "KXU3-25OCT-T3.8"
    },
    {
      "name": "category",
      "in": "query",
      "description": "Category, default is US_EVENT, currently only US_EVENT is supported.",
      "required": false,
      "schema": {
        "type": "string",
        "enum": [
          "US_EVENT"
        ]
      },
      "example": "US_EVENT"
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
                "instrument_id",
                "last_trade_time",
                "name",
                "no_ask",
                "no_ask_size",
                "no_bid",
                "no_bid_size",
                "open_interest",
                "price",
                "symbol",
                "volume",
                "yes_ask",
                "yes_ask_size",
                "yes_bid",
                "yes_bid_size"
              ],
              "type": "object",
              "properties": {
                "instrument_id": {
                  "type": "string",
                  "description": "Unique id of the event market.",
                  "example": "504279491"
                },
                "symbol": {
                  "type": "string",
                  "description": "Symbol of the event market.",
                  "example": "KXCPI-26JAN-T0.3"
                },
                "name": {
                  "type": "string",
                  "description": "Name of the event market.",
                  "example": "Will CPI rise more than 0.3% in January 2026?"
                },
                "price": {
                  "type": "string",
                  "description": "The current market price for buying or selling an event contract",
                  "example": "0.13"
                },
                "volume": {
                  "type": "string",
                  "description": "Number of contracts bought on this event market.",
                  "example": "32"
                },
                "last_trade_time": {
                  "type": "integer",
                  "description": "Price for the last traded YES contract on this market.",
                  "format": "int64",
                  "example": 1768861137000
                },
                "open_interest": {
                  "type": "string",
                  "description": "Number of contracts bought on this event market disconsidering netting.",
                  "example": "14240"
                },
                "yes_bid": {
                  "type": "string",
                  "description": "Price for the highest YES buy offer on this event market.",
                  "example": "0.08"
                },
                "yes_bid_size": {
                  "type": "string",
                  "description": "Size for the highest YES buy offer on this event market.",
                  "example": "2115"
                },
                "yes_ask": {
                  "type": "string",
                  "description": "Price for the lowest YES sell offer on this event market.",
                  "example": "0.13"
                },
                "yes_ask_size": {
                  "type": "string",
                  "description": "Size for the lowest YES sell offer on this event market.",
                  "example": "543"
                },
                "no_bid": {
                  "type": "string",
                  "description": "Price for the highest NO buy offer on this event market.",
                  "example": "0.87"
                },
                "no_bid_size": {
                  "type": "string",
                  "description": "Size for the highest NO buy offer on this event market.",
                  "example": "543"
                },
                "no_ask": {
                  "type": "string",
                  "description": "Price for the lowest NO sell offer on this event market.",
                  "example": "0.92"
                },
                "no_ask_size": {
                  "type": "string",
                  "description": "Size for the lowest NO sell offer on this event market.",
                  "example": "2115"
                }
              },
              "description": "Event snapshot",
              "title": "EventSnapshotVo"
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
    "name": "List Event Snapshots",
    "description": {
      "content": "Retrieves a real-time snapshot for an event instrument.",
      "type": "text/plain"
    },
    "url": {
      "path": [
        "market-data",
        "event-contracts",
        "snapshots",
        "list"
      ],
      "host": [
        "{{baseUrl}}"
      ],
      "query": [
        {
          "disabled": false,
          "description": {
            "content": "(Required) Symbol of the event market, supports JSON array format, multiple symbols separated by commas; maximum 100 symbols per query.",
            "type": "text/plain"
          },
          "key": "symbols",
          "value": ""
        },
        {
          "disabled": false,
          "description": {
            "content": "Category, default is US_EVENT, currently only US_EVENT is supported.",
            "type": "text/plain"
          },
          "key": "category",
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
