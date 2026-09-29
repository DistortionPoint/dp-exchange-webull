# Batch Place Orders

Places multiple orders in a single request.<br/>A maximum of 50 orders can be submitted once, Currently only stocks are supported. This service is not currently available to all clients. Please contact Webull if you require assistance.

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
  "path": "/trading/orders/batch-place",
  "method": "post",
  "tags": [
    "Trading"
  ],
  "description": "Places multiple orders in a single request.<br/>A maximum of 50 orders can be submitted once, Currently only stocks are supported. This service is not currently available to all clients. Please contact Webull if you require assistance.",
  "operationId": "Order Batch Place",
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
            "account_id",
            "batch_orders"
          ],
          "type": "object",
          "properties": {
            "account_id": {
              "type": "string",
              "description": "Account identifier",
              "example": "93IUJ28O9VO2KBGHDHR4H9"
            },
            "batch_orders": {
              "type": "array",
              "description": "Batch Orders",
              "items": {
                "required": [
                  "client_order_id",
                  "combo_type",
                  "entrust_type",
                  "instrument_type",
                  "market",
                  "order_type",
                  "quantity",
                  "side",
                  "support_trading_session",
                  "symbol",
                  "time_in_force"
                ],
                "type": "object",
                "properties": {
                  "client_order_id": {
                    "type": "string",
                    "description": "Unique client-defined identifier for the order.<br/> Maximum length is 32 characters and must be unique per account.<br/> Used to track or reference the order when interacting with the system.",
                    "example": "0KGOHL4PR2SLC0DKIND4TI0002"
                  },
                  "combo_type": {
                    "type": "string",
                    "description": "Type of order combination. Currently only NORMAL is supported. It may be expanded to support other types in the future<br/> &bull; NORMAL: Indicates a standard single order",
                    "example": "NORMAL"
                  },
                  "instrument_type": {
                    "type": "string",
                    "description": "Type of financial instrument associated with the request.",
                    "example": "EQUITY",
                    "enum": [
                      "EQUITY"
                    ]
                  },
                  "entrust_type": {
                    "type": "string",
                    "description": "Specifies the method for placing the order.<br/> &bull; QTY: Order specified by quantity of shares or units.",
                    "example": "QTY",
                    "enum": [
                      "QTY"
                    ]
                  },
                  "support_trading_session": {
                    "type": "string",
                    "description": "Specifies the trading session for the order. Applicable to U.S. stock market orders only.<br/> Algorithmic trading order currently supports only regular trading hours.<br/> &bull; NIGHT: Only supports night trading.<br/> &bull; ALL: Include extended trading hours.<br/> &bull; CORE: Only support regular trading hours.",
                    "example": "CORE",
                    "enum": [
                      "ALL",
                      "CORE",
                      "NIGHT"
                    ]
                  },
                  "symbol": {
                    "type": "string",
                    "description": "Trading symbol of the financial instrument. Represents the unique identifier of the security in the specified market (e.g., ticker symbol for equities).",
                    "example": "BULL"
                  },
                  "market": {
                    "type": "string",
                    "description": "Market code indicating the trading venue or regulatory region of the financial instrument. Used together with symbol and instrument_type to uniquely identify a tradable instrument.",
                    "example": "US",
                    "enum": [
                      "US"
                    ]
                  },
                  "side": {
                    "type": "string",
                    "description": "The order side indicating the intended trading direction of the transaction. <br/> The meaning of side may vary depending on the instrument_type and account type (e.g., margin vs. cash).",
                    "example": "BUY",
                    "enum": [
                      "BUY",
                      "SELL"
                    ]
                  },
                  "order_type": {
                    "type": "string",
                    "description": "Specifies the type of order to be placed. Determines how the order will be executed in the market.<br/>Available order types depend on the market and instrument type.<br/>&nbsp; &bull; <b>LIMIT:</b> Limit Order<br/>&nbsp; &bull; <b>MARKET:</b> Market Order<br/>",
                    "example": "MARKET",
                    "enum": [
                      "MARKET",
                      "LIMIT"
                    ]
                  },
                  "time_in_force": {
                    "type": "string",
                    "description": "Specifies the duration for which the order remains active in the market (Time-In-Force).<br/> &bull; DAY: The order is valid only for the current trading day and expires at the end of the day.",
                    "example": "DAY",
                    "enum": [
                      "DAY"
                    ]
                  },
                  "quantity": {
                    "type": "string",
                    "description": "Transaction quantity. You can specify decimals when placing fractional lot orders for US stocks.",
                    "example": "1"
                  },
                  "limit_price": {
                    "type": "string",
                    "description": "Limit price of the order. Required when order_type is LIMIT, STOP_LOSS_LIMIT.<br/> Specifies the maximum (for buy) or minimum (for sell) price at which the order can be executed.<br/> When event_trade_mode is set for an event contract trade, limit_price is not required.",
                    "example": "11.0"
                  }
                },
                "description": "Batch Orders",
                "title": "OrderCommonBatchPlaceItemParam"
              }
            }
          },
          "description": "Order Place Request Body",
          "title": "OrderCommonBatchPlaceParam"
        }
      }
    }
  },
  "responses": {
    "200": {
      "description": "Request successful",
      "content": {
        "application/json": {
          "schema": {
            "required": [
              "batch_orders",
              "failed",
              "success",
              "total"
            ],
            "type": "object",
            "properties": {
              "total": {
                "type": "integer",
                "description": "The total number of orders submitted each time",
                "format": "int32"
              },
              "success": {
                "type": "integer",
                "description": "The number of orders successfully submitted to the webull system",
                "format": "int32"
              },
              "failed": {
                "type": "integer",
                "description": "The number of failed order submitted to the webull system",
                "format": "int32"
              },
              "batch_orders": {
                "type": "array",
                "description": "Batch Order place result",
                "items": {
                  "type": "object",
                  "properties": {
                    "client_order_id": {
                      "type": "string",
                      "description": "Client-defined order identifier. Returned in the response for simple orders.<br/> Represents the unique order ID assigned by the user when placing the order for NORMAL order.",
                      "example": "0KGOHL4PR2SLC0DKIND4TI0002"
                    },
                    "order_id": {
                      "type": "string",
                      "description": "System-generated order identifier. Returned in the response for simple orders.<br/> Represents the unique Webull order ID assigned by the system when placing the order for NORMAL order.",
                      "example": "80HG7CPSFDPCAL3TP66LKBAS69"
                    },
                    "error_code": {
                      "type": "string",
                      "description": "Order place failed code",
                      "example": "OPENAPI_NO_TRADING_TIME"
                    },
                    "message": {
                      "type": "string",
                      "description": "Order place failed and detail failed reason.",
                      "example": "Non-trading time."
                    }
                  },
                  "description": "Batch Order place result",
                  "title": "OrderResp"
                }
              }
            },
            "title": "BatchOrderResp"
          },
          "examples": {
            " Special Instructions": {
              "description": " Special Instructions",
              "value": {
                "total": 2,
                "success": 1,
                "failed": 1,
                "batch_orders": [
                  {
                    "client_order_id": "0KGOHL4PR2SLC0DKIND4TI0001",
                    "order_id": "80HG7CPSFDPCAL3TP66LKBAS69"
                  },
                  {
                    "client_order_id": "0KGOHL4PR2SLC0DKIND4TI0002",
                    "error_code": "OAUTH_OPENAPI_NO_TRADING_TIME",
                    "message": "Non-trading time."
                  }
                ]
              }
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
      "content": {
        "application/json": {
          "schema": {
            "type": "object",
            "properties": {
              "error_code": {
                "type": "string",
                "description": "error code",
                "example": "OPENAPI_NO_NIGHT_TRADING_TIME"
              },
              "message": {
                "type": "string",
                "description": "error message",
                "example": "The current period does not support placing night orders"
              }
            },
            "description": "Business Response",
            "title": "BizResponse"
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
    "account_id": "93IUJ28O9VO2KBGHDHR4H9",
    "batch_orders": [
      {
        "client_order_id": "0KGOHL4PR2SLC0DKIND4TI0002",
        "combo_type": "NORMAL",
        "instrument_type": "EQUITY",
        "entrust_type": "QTY",
        "support_trading_session": "CORE",
        "symbol": "BULL",
        "market": "US",
        "side": "BUY",
        "order_type": "MARKET",
        "time_in_force": "DAY",
        "quantity": "1",
        "limit_price": "11.0"
      }
    ]
  },
  "postman": {
    "name": "Batch Place Orders",
    "description": {
      "content": "Places multiple orders in a single request.<br/>A maximum of 50 orders can be submitted once, Currently only stocks are supported. This service is not currently available to all clients. Please contact Webull if you require assistance.",
      "type": "text/plain"
    },
    "url": {
      "path": [
        "trading",
        "orders",
        "batch-place"
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
