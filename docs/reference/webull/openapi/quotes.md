# List Stock Depths

Retrieves the latest bid/ask quotes for a stock at the specified depth (price, quantity, order details).

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
  "path": "/market-data/stocks/depths/list",
  "method": "get",
  "tags": [
    "Stocks Market Data"
  ],
  "description": "Retrieves the latest bid/ask quotes for a stock at the specified depth (price, quantity, order details).",
  "operationId": "quotes",
  "parameters": [
    {
      "name": "symbol",
      "in": "query",
      "description": "Security symbol.",
      "required": true,
      "schema": {
        "type": "string"
      },
      "example": "GOOG"
    },
    {
      "name": "category",
      "in": "query",
      "description": "Security type. Category values are as shown in the enum; US_OPTION type query is currently not supported.",
      "required": true,
      "schema": {
        "type": "string",
        "enum": [
          "US_STOCK",
          "US_ETF"
        ]
      },
      "example": "US_STOCK"
    },
    {
      "name": "depth",
      "in": "query",
      "description": "Market depth, L1-1 level, L2-default 10 levels, etc.",
      "required": true,
      "schema": {
        "type": "string"
      },
      "example": 10
    },
    {
      "name": "overnight_required",
      "in": "query",
      "description": "Whether to include overnight trading data.",
      "required": true,
      "schema": {
        "type": "string",
        "default": "false"
      },
      "example": false
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
              "asks",
              "bids",
              "instrument_id",
              "quote_time",
              "symbol"
            ],
            "type": "object",
            "properties": {
              "symbol": {
                "type": "string",
                "description": "Security symbol",
                "example": "F"
              },
              "instrument_id": {
                "type": "string",
                "description": "Instrument ID",
                "example": "913255275"
              },
              "quote_time": {
                "type": "string",
                "description": "Quote time",
                "example": "1640688000000"
              },
              "asks": {
                "type": "array",
                "description": "Array of ask orders",
                "items": {
                  "required": [
                    "order",
                    "price",
                    "size"
                  ],
                  "type": "object",
                  "properties": {
                    "price": {
                      "type": "string",
                      "description": "Price",
                      "example": "13.9"
                    },
                    "size": {
                      "type": "string",
                      "description": "Size (Quantity)",
                      "example": "5"
                    },
                    "order": {
                      "type": "array",
                      "description": "Array of order details",
                      "items": {
                        "required": [
                          "mpid",
                          "size"
                        ],
                        "type": "object",
                        "properties": {
                          "mpid": {
                            "type": "string",
                            "description": "Market participant ID",
                            "example": "NSDQ"
                          },
                          "size": {
                            "type": "string",
                            "description": "Size (Quantity)",
                            "example": "5"
                          }
                        },
                        "description": "OrderItem",
                        "title": "OrderItem"
                      }
                    },
                    "broker": {
                      "type": "array",
                      "items": {
                        "required": [
                          "bid",
                          "name"
                        ],
                        "type": "object",
                        "properties": {
                          "bid": {
                            "type": "string",
                            "description": "Broker ID",
                            "example": "1"
                          },
                          "name": {
                            "type": "string",
                            "description": "Broker Name",
                            "example": "2"
                          }
                        },
                        "description": "BrokerItem",
                        "title": "BrokerItem"
                      }
                    }
                  },
                  "description": "AskItem",
                  "title": "AskItem"
                }
              },
              "bids": {
                "type": "array",
                "description": "Array of bid orders",
                "items": {
                  "required": [
                    "order",
                    "price",
                    "size"
                  ],
                  "type": "object",
                  "properties": {
                    "price": {
                      "type": "string",
                      "description": "Price",
                      "example": "13.9"
                    },
                    "size": {
                      "type": "string",
                      "description": "Size (Quantity)",
                      "example": "5"
                    },
                    "order": {
                      "type": "array",
                      "description": "Array of order details",
                      "items": {
                        "required": [
                          "mpid",
                          "size"
                        ],
                        "type": "object",
                        "properties": {
                          "mpid": {
                            "type": "string",
                            "description": "Market participant ID",
                            "example": "NSDQ"
                          },
                          "size": {
                            "type": "string",
                            "description": "Size (Quantity)",
                            "example": "5"
                          }
                        },
                        "description": "OrderItem",
                        "title": "OrderItem"
                      }
                    },
                    "broker": {
                      "type": "array",
                      "items": {
                        "required": [
                          "bid",
                          "name"
                        ],
                        "type": "object",
                        "properties": {
                          "bid": {
                            "type": "string",
                            "description": "Broker ID",
                            "example": "1"
                          },
                          "name": {
                            "type": "string",
                            "description": "Broker Name",
                            "example": "2"
                          }
                        },
                        "description": "BrokerItem",
                        "title": "BrokerItem"
                      }
                    }
                  },
                  "description": "BidItem",
                  "title": "BidItem"
                }
              }
            },
            "description": "QuoteVo",
            "title": "QuoteVo"
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
    "name": "List Stock Depths",
    "description": {
      "content": "Retrieves the latest bid/ask quotes for a stock at the specified depth (price, quantity, order details).",
      "type": "text/plain"
    },
    "url": {
      "path": [
        "market-data",
        "stocks",
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
            "content": "(Required) Security symbol.",
            "type": "text/plain"
          },
          "key": "symbol",
          "value": ""
        },
        {
          "disabled": false,
          "description": {
            "content": "(Required) Security type. Category values are as shown in the enum; US_OPTION type query is currently not supported.",
            "type": "text/plain"
          },
          "key": "category",
          "value": ""
        },
        {
          "disabled": false,
          "description": {
            "content": "(Required) Market depth, L1-1 level, L2-default 10 levels, etc.",
            "type": "text/plain"
          },
          "key": "depth",
          "value": ""
        },
        {
          "disabled": false,
          "description": {
            "content": "(Required) Whether to include overnight trading data.",
            "type": "text/plain"
          },
          "key": "overnight_required",
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
