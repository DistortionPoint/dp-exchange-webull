# List Stock Historical Bars

Retrieves the most recent N historical bars for multiple stock symbols. Daily and above are forward-adjusted; minute bars are unadjusted.

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
  "path": "/market-data/stocks/bars/list",
  "method": "post",
  "tags": [
    "Stocks Market Data"
  ],
  "description": "Retrieves the most recent N historical bars for multiple stock symbols. Daily and above are forward-adjusted; minute bars are unadjusted.",
  "operationId": "historicalBars",
  "parameters": [
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
  "requestBody": {
    "content": {
      "application/json": {
        "schema": {
          "required": [
            "category",
            "symbols",
            "timespan"
          ],
          "type": "object",
          "properties": {
            "symbols": {
              "type": "array",
              "description": "List of security symbols, supports JSON array format, multiple symbols separated by commas; maximum 20 symbols per query.",
              "example": [
                "AAPL",
                "GOOG"
              ],
              "items": {
                "type": "string",
                "description": "List of security symbols, supports JSON array format, multiple symbols separated by commas; maximum 20 symbols per query.",
                "example": "[\"AAPL\",\"GOOG\"]"
              }
            },
            "category": {
              "type": "string",
              "description": "Security type. Category values are as shown in the enum; US_OPTION type query is currently not supported.",
              "example": "US_STOCK",
              "enum": [
                "US_STOCK",
                "US_ETF"
              ]
            },
            "timespan": {
              "type": "string",
              "description": "Bar time granularity.",
              "example": "D",
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
            "count": {
              "type": "integer",
              "description": "Number of bars, default 200, maximum limit 1200 (M1 supports up to 1650).",
              "format": "int32",
              "example": 500
            },
            "real_time_required": {
              "type": "boolean",
              "description": "Return the latest trading data, default is Y;\\nN: Pulls only the completed bars from the previous period at the nearest whole hour at the time of request.\\nY: The returned data includes the latest market data.",
              "example": false
            },
            "trading_sessions": {
              "type": "string",
              "description": "Specify trading session(s). Multiple sessions separated by \",\".",
              "example": "PRE,RTH",
              "enum": [
                "PRE",
                "RTH",
                "ATH",
                "OVN"
              ]
            },
            "start_time": {
              "type": "integer",
              "description": "Start time as timestamp in milliseconds. Used to specify the beginning of the time range for bar data.",
              "format": "int64",
              "example": 1711262998500
            },
            "end_time": {
              "type": "integer",
              "description": "End time as timestamp in milliseconds. Used to specify the end of the time range for bar data. Delayed permission will automatically offset the time.",
              "format": "int64",
              "example": 1711349398500
            }
          },
          "title": "BatchBarRequest"
        }
      }
    },
    "required": true
  },
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
                "description": "List of batch bar data results, each element contains historical bar data for one stock.",
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
                      "description": "Futures contract symbol used in trading and market data, e.g. front-month code provided by the exchange.",
                      "example": "SILZ5"
                    },
                    "instrument_id": {
                      "type": "string",
                      "description": "Unique instrument identifier for this futures contract in the Webull system or exchange.",
                      "example": "470059643"
                    },
                    "result": {
                      "type": "array",
                      "description": "List of historical bar data for this futures.",
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
                  "description": "Historical K-line data for a single futures",
                  "title": "SymbolData"
                }
              }
            },
            "description": "Batch historical K-line data response object",
            "title": "BatchBarsVo"
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
  "jsonRequestBodyExample": {
    "symbols": [
      "AAPL",
      "GOOG"
    ],
    "category": "US_STOCK",
    "timespan": "D",
    "count": 500,
    "real_time_required": false,
    "trading_sessions": "PRE,RTH",
    "start_time": 1711262998500,
    "end_time": 1711349398500
  },
  "postman": {
    "name": "List Stock Historical Bars",
    "description": {
      "content": "Retrieves the most recent N historical bars for multiple stock symbols. Daily and above are forward-adjusted; minute bars are unadjusted.",
      "type": "text/plain"
    },
    "url": {
      "path": [
        "market-data",
        "stocks",
        "bars",
        "list"
      ],
      "host": [
        "{{baseUrl}}"
      ],
      "query": [],
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
        "key": "Content-Type",
        "value": "application/json"
      },
      {
        "key": "Accept",
        "value": "application/json"
      }
    ],
    "method": "POST",
    "body": {
      "mode": "raw",
      "raw": "",
      "options": {
        "raw": {
          "language": "json"
        }
      }
    }
  }
}
```
