# List Event Depths

Retrieves the order book for an event instrument. Only yes/no bids are returned (in binary markets a yes bid at X equals a no ask at 100-X).

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
  "path": "/market-data/event-contracts/depths/list",
  "method": "get",
  "tags": [
    "Event Market Data"
  ],
  "description": "Retrieves the order book for an event instrument. Only yes/no bids are returned (in binary markets a yes bid at X equals a no ask at 100-X).",
  "operationId": "eventDepth",
  "parameters": [
    {
      "name": "symbol",
      "in": "query",
      "description": "Symbol of the event market.",
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
      "name": "depth",
      "in": "query",
      "description": "Depth of buying and selling orders, default 10 levels, etc.",
      "required": false,
      "schema": {
        "type": "string"
      },
      "example": 10
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
                "no_asks",
                "no_bids",
                "quote_time",
                "symbol",
                "yes_asks",
                "yes_bids"
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
                "quote_time": {
                  "type": "integer",
                  "description": "Quotation Time.",
                  "format": "int64",
                  "example": 1768872168870
                },
                "yes_bids": {
                  "type": "array",
                  "description": "Yes, buy order array.",
                  "items": {
                    "required": [
                      "price",
                      "size"
                    ],
                    "type": "object",
                    "properties": {
                      "price": {
                        "type": "string",
                        "description": "Price",
                        "example": "0.13"
                      },
                      "size": {
                        "type": "string",
                        "description": "Trading volume.",
                        "example": "543"
                      }
                    },
                    "description": "No, sell order array.",
                    "title": "AskBid"
                  }
                },
                "yes_asks": {
                  "type": "array",
                  "description": "Yes, sell order array.",
                  "items": {
                    "required": [
                      "price",
                      "size"
                    ],
                    "type": "object",
                    "properties": {
                      "price": {
                        "type": "string",
                        "description": "Price",
                        "example": "0.13"
                      },
                      "size": {
                        "type": "string",
                        "description": "Trading volume.",
                        "example": "543"
                      }
                    },
                    "description": "No, sell order array.",
                    "title": "AskBid"
                  }
                },
                "no_bids": {
                  "type": "array",
                  "description": "No, buy order array.",
                  "items": {
                    "required": [
                      "price",
                      "size"
                    ],
                    "type": "object",
                    "properties": {
                      "price": {
                        "type": "string",
                        "description": "Price",
                        "example": "0.13"
                      },
                      "size": {
                        "type": "string",
                        "description": "Trading volume.",
                        "example": "543"
                      }
                    },
                    "description": "No, sell order array.",
                    "title": "AskBid"
                  }
                },
                "no_asks": {
                  "type": "array",
                  "description": "No, sell order array.",
                  "items": {
                    "required": [
                      "price",
                      "size"
                    ],
                    "type": "object",
                    "properties": {
                      "price": {
                        "type": "string",
                        "description": "Price",
                        "example": "0.13"
                      },
                      "size": {
                        "type": "string",
                        "description": "Trading volume.",
                        "example": "543"
                      }
                    },
                    "description": "No, sell order array.",
                    "title": "AskBid"
                  }
                }
              },
              "description": "Event depth",
              "title": "EventDepthVo"
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
    "name": "List Event Depths",
    "description": {
      "content": "Retrieves the order book for an event instrument. Only yes/no bids are returned (in binary markets a yes bid at X equals a no ask at 100-X).",
      "type": "text/plain"
    },
    "url": {
      "path": [
        "market-data",
        "event-contracts",
        "depths",
        "list"
      ],
      "host": [
        "{{baseUrl}}"
      ],
      "query": [
        {
          "disabled": false,
          "description": {
            "content": "(Required) Symbol of the event market.",
            "type": "text/plain"
          },
          "key": "symbol",
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
        },
        {
          "disabled": false,
          "description": {
            "content": "Depth of buying and selling orders, default 10 levels, etc.",
            "type": "text/plain"
          },
          "key": "depth",
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
