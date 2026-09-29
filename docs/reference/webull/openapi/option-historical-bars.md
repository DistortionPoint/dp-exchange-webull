# List Option Historical Bars

Retrieves the most recent N historical bars for one or more option codes.

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
  "path": "/market-data/options/bars/list",
  "method": "get",
  "tags": [
    "Options Market Data"
  ],
  "description": "Retrieves the most recent N historical bars for one or more option codes.",
  "operationId": "optionHistoricalBars",
  "parameters": [
    {
      "name": "symbols",
      "in": "query",
      "description": "List of option symbols, separated by commas; maximum 20 symbols per query. Example: AAPL260522C00300000",
      "required": true,
      "schema": {
        "type": "string"
      },
      "example": "AAPL260522C00300000"
    },
    {
      "name": "category",
      "in": "query",
      "description": "Security type. Currently only `US_OPTION` is supported for this interface.",
      "required": true,
      "schema": {
        "type": "string",
        "enum": [
          "US_OPTION"
        ]
      },
      "example": "US_OPTION"
    },
    {
      "name": "timespan",
      "in": "query",
      "description": "Bar time granularity. eg: M1, M5, M15, M30, M60, M120, M240, D, W, M, Y",
      "required": true,
      "schema": {
        "type": "string",
        "enum": [
          "M1",
          "M5",
          "M15",
          "M30",
          "M60",
          "M120",
          "M240",
          "D",
          "W",
          "M",
          "Y"
        ]
      },
      "example": "M1"
    },
    {
      "name": "count",
      "in": "query",
      "description": "Number of bars, maximum limit 1200 .",
      "required": false,
      "schema": {
        "type": "string",
        "default": "200"
      },
      "example": 200
    },
    {
      "name": "real_time_required",
      "in": "query",
      "description": "Include the latest data",
      "required": false,
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
              "result"
            ],
            "type": "object",
            "properties": {
              "result": {
                "type": "array",
                "description": "List of batch bar data results, each element contains historical bar data for one option.",
                "items": {
                  "required": [
                    "instrument_id",
                    "result",
                    "symbol"
                  ],
                  "type": "object",
                  "properties": {
                    "symbol": {
                      "type": "string",
                      "description": "Option contract symbol used in trading and market data, e.g. front-month code provided by the exchange.",
                      "example": "AAPL260522C00300000"
                    },
                    "instrument_id": {
                      "type": "string",
                      "description": "Unique instrument identifier for this option contract in the Webull system or exchange.",
                      "example": "470059643"
                    },
                    "result": {
                      "type": "array",
                      "description": "List of historical bar data for this option.",
                      "items": {
                        "required": [
                          "close",
                          "high",
                          "low",
                          "open",
                          "time",
                          "volume"
                        ],
                        "type": "object",
                        "properties": {
                          "time": {
                            "type": "string",
                            "description": "Bar UTC time",
                            "example": "2021-12-28T09:00:09.945+0000"
                          },
                          "open": {
                            "type": "string",
                            "description": "Open price",
                            "example": "1.3362"
                          },
                          "close": {
                            "type": "string",
                            "description": "Close price",
                            "example": "1.3362"
                          },
                          "high": {
                            "type": "string",
                            "description": "High price",
                            "example": "1.3362"
                          },
                          "low": {
                            "type": "string",
                            "description": "Low price",
                            "example": "1.3362"
                          },
                          "volume": {
                            "type": "string",
                            "description": "Volume",
                            "example": "10"
                          }
                        },
                        "description": "Single K-line price record",
                        "title": "PriceRecord"
                      }
                    }
                  },
                  "description": "Historical K-line data for a single option",
                  "title": "OptionSymbolData"
                }
              }
            },
            "description": "Batch historical K-line data response object",
            "title": "OptionBatchBarsVo"
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
    "name": "List Option Historical Bars",
    "description": {
      "content": "Retrieves the most recent N historical bars for one or more option codes.",
      "type": "text/plain"
    },
    "url": {
      "path": [
        "market-data",
        "options",
        "bars",
        "list"
      ],
      "host": [
        "{{baseUrl}}"
      ],
      "query": [
        {
          "disabled": false,
          "description": {
            "content": "(Required) List of option symbols, separated by commas; maximum 20 symbols per query. Example: AAPL260522C00300000",
            "type": "text/plain"
          },
          "key": "symbols",
          "value": ""
        },
        {
          "disabled": false,
          "description": {
            "content": "(Required) Security type. Currently only `US_OPTION` is supported for this interface.",
            "type": "text/plain"
          },
          "key": "category",
          "value": ""
        },
        {
          "disabled": false,
          "description": {
            "content": "(Required) Bar time granularity. eg: M1, M5, M15, M30, M60, M120, M240, D, W, M, Y",
            "type": "text/plain"
          },
          "key": "timespan",
          "value": ""
        },
        {
          "disabled": false,
          "description": {
            "content": "Number of bars, maximum limit 1200 .",
            "type": "text/plain"
          },
          "key": "count",
          "value": ""
        },
        {
          "disabled": false,
          "description": {
            "content": "Include the latest data",
            "type": "text/plain"
          },
          "key": "real_time_required",
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
