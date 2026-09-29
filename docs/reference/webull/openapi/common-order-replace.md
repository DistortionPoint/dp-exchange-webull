# Replace Order

Modifies equity, options and futures orders, including simple orders. For crypto trading, this feature is currently not supported.<br/>• Futures order modification rules:<br/>&nbsp;&nbsp;- For market orders, only `quantity` can be modified.<br/>&nbsp;&nbsp;- For limit orders, only `order_type`, `time_in_force`, `quantity` and `limit_price` can be modified; if modifying `order_type`, it can only be changed to `market`.<br/>&nbsp;&nbsp;- For stop orders, only `order_type`, `time_in_force`, `quantity` and `stop_price` can be modified; if modifying `order_type`, it can only be changed to `market`.<br/>&nbsp;&nbsp;- For stop limit orders, only `order_type`, `time_in_force`, `quantity`, `limit_price` and `stop_price` can be modified; if modifying `order_type`, it can only be changed to `limit`.<br/>&nbsp;&nbsp;- For trailing stop orders, only `trailing_stop_step` can be modified; `order_type` , `trailing_type` and `time_in_force` cannot be modified.

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
  "path": "/trading/orders/replace",
  "method": "post",
  "tags": [
    "Trading"
  ],
  "description": "Modifies equity, options and futures orders, including simple orders. For crypto trading, this feature is currently not supported.<br/>• Futures order modification rules:<br/>&nbsp;&nbsp;- For market orders, only `quantity` can be modified.<br/>&nbsp;&nbsp;- For limit orders, only `order_type`, `time_in_force`, `quantity` and `limit_price` can be modified; if modifying `order_type`, it can only be changed to `market`.<br/>&nbsp;&nbsp;- For stop orders, only `order_type`, `time_in_force`, `quantity` and `stop_price` can be modified; if modifying `order_type`, it can only be changed to `market`.<br/>&nbsp;&nbsp;- For stop limit orders, only `order_type`, `time_in_force`, `quantity`, `limit_price` and `stop_price` can be modified; if modifying `order_type`, it can only be changed to `limit`.<br/>&nbsp;&nbsp;- For trailing stop orders, only `trailing_stop_step` can be modified; `order_type` , `trailing_type` and `time_in_force` cannot be modified.",
  "operationId": "Common Order Replace",
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
            "modify_orders"
          ],
          "type": "object",
          "properties": {
            "account_id": {
              "type": "string",
              "description": "Account identifier",
              "example": "93IUJ28O9VO2KBGHDHR4H9"
            },
            "modify_orders": {
              "type": "array",
              "description": "Order Details",
              "items": {
                "required": [
                  "client_order_id"
                ],
                "type": "object",
                "properties": {
                  "client_order_id": {
                    "type": "string",
                    "description": "Unique client-defined identifier for the order.<br/> Maximum length is 32 characters and must be unique per account.<br/> Used to track or reference the order when interacting with the system.",
                    "example": "0KGOHL4PR2SLC0DKIND4TI0002"
                  },
                  "time_in_force": {
                    "type": "string",
                    "description": "Specifies the duration for which the order remains active in the market (Time-In-Force).<br/> U.S. Stock, Futures, and Options trading support the following Time in Force (TIF) values: DAY and GTC.<br/> Event trading supports the following Time in Force (TIF) values: DAY, GTC, IOC, GTD, and FOK.<br/> Algorithmic trading order supports the following Time in Force (TIF) values: DAY.<br/> &bull; DAY: The order is valid only for the current trading day and expires at the end of the day.<br/> &bull; GTC: Good-Till-Canceled, the order remains active until it is executed, explicitly canceled, or reaches the maximum allowed duration (typically 60 days).<br/> &bull; IOC: Immediate-Or-Cancel, the order attempts to execute immediately. Any portion that can be filled right away will be executed; any unfilled remainder is immediately cancelled.<br/> &bull; GTD: order that will automatically expire and be cancelled at a specific future date and time.<br/> &bull; FOK: Fill or Kill. The order must be filled in its entirety immediately; otherwise, the entire order will be canceled.",
                    "example": "DAY",
                    "enum": [
                      "DAY",
                      "GTC",
                      "IOC",
                      "GTD",
                      "FOK"
                    ]
                  },
                  "stop_price": {
                    "type": "string",
                    "description": "Stop price of the order. Required when order_type is STOP_LOSS or STOP_LOSS_LIMIT.<br/> Specifies the trigger price at which the stop order becomes active.",
                    "example": "11.0"
                  },
                  "limit_price": {
                    "type": "string",
                    "description": "Limit price of the order. Required when order_type is LIMIT, STOP_LOSS_LIMIT.<br/> Specifies the maximum (for buy) or minimum (for sell) price at which the order can be executed.",
                    "example": "11.0"
                  },
                  "quantity": {
                    "type": "string",
                    "description": "Transaction quantity. You can specify decimals when placing fractional lot orders for US stocks.",
                    "example": "1"
                  },
                  "order_type": {
                    "type": "string",
                    "description": "Specifies the type of order to be placed. Determines how the order will be executed in the market.<br/>Available order types depend on the market and instrument type.<br/>For stock, options and futures trading: <br/>&nbsp; &bull; <b>LIMIT:</b> Limit Order<br/>&nbsp; &bull; <b>MARKET:</b> Market Order<br/>&nbsp; &bull; <b>STOP_LOSS:</b> Stop Order<br/>&nbsp; &bull; <b>STOP_LOSS_LIMIT:</b> Stop Limit Order<br/>&nbsp; &bull; <b>TRAILING_STOP_LOSS:</b> Trailing Stop Order, Options not supported<br/>For event trading: <br/>&nbsp; &bull; Supported order types: LIMIT.<br/> The following order types are supported only for institutional stock orders.<br/>&nbsp; &bull; <b>MARKET_ON_OPEN:</b> Opening market order<br/> &nbsp; &bull; <b>MARKET_ON_CLOSE:</b> Closing market order<br/> &nbsp; &bull; <b>LIMIT_ON_OPEN:</b> Opening market limit order<br/>",
                    "example": "MARKET",
                    "enum": [
                      "MARKET",
                      "LIMIT",
                      "STOP_LOSS",
                      "STOP_LOSS_LIMIT",
                      "TRAILING_STOP_LOSS",
                      "MARKET_ON_OPEN",
                      "MARKET_ON_CLOSE",
                      "LIMIT_ON_OPEN"
                    ]
                  },
                  "trailing_type": {
                    "type": "string",
                    "description": "When market continues to fall, the stop price to buy follows, or trails, the lowest price of a stock by a trail that you set. <br/> &bull; AMOUNT: By amount. <br/> &bull; PERCENTAGE: By percentage.",
                    "example": "AMOUNT"
                  },
                  "trailing_stop_step": {
                    "type": "string",
                    "description": "Trailing Stop Spread. If the tracking type is percentage, the tracking spread can not exceed 1,0.01 means 1%",
                    "example": "1"
                  },
                  "target_vol_percent": {
                    "type": "string",
                    "description": "The target participation percentage of the algorithmic order relative to the total expected market trading volume. This parameter limits the highest percentage of market volume that the POV algorithm is allowed to participate in at any time.  The value must be a positive integer between 1 and 20 (inclusive).",
                    "example": "10"
                  },
                  "max_target_percent": {
                    "type": "string",
                    "description": "The maximum participation rate of the algorithmic order relative to the total market traded volume. This parameter defines the intended execution aggressiveness for TWAP and VWAP strategies by specifying the proportion of market volume the algorithm aims to trade over the execution period. The value must be a positive integer between 1 and 20 (inclusive).",
                    "example": "10"
                  },
                  "algo_start_time": {
                    "type": "string",
                    "description": "The scheduled start time of the algorithmic order. Use US Eastern Time (ET). The algorithm will not begin execution before this time. The value must be in HH:mm:ss format (24-hour clock) and must be later than the current system time at the moment the order is submitted.",
                    "example": "09:30:00"
                  },
                  "algo_end_time": {
                    "type": "string",
                    "description": "The scheduled end time of the algorithmic order. Use US Eastern Time (ET). The value must be in HH:mm:ss format (24-hour clock).",
                    "example": "16:00:00"
                  },
                  "legs": {
                    "type": "array",
                    "description": "Option Leg detail. Only required when modifying option orders.",
                    "items": {
                      "required": [
                        "id",
                        "quantity"
                      ],
                      "type": "object",
                      "properties": {
                        "id": {
                          "type": "string",
                          "description": "Unique defined identifier for the leg.",
                          "example": "G2JAJPOR4KUA0F5I9LONH8J83A"
                        },
                        "quantity": {
                          "type": "string",
                          "description": "Quantity of the order or strategy leg. <br/>For stock legs, specifies the number of shares to transact <br/>For option legs, specifies the number of option contracts to transact for this leg and is expressed in whole contracts.",
                          "example": "1"
                        }
                      },
                      "description": "Option Leg detail. Only required when modifying option orders.",
                      "title": "OptionCommonReplaceLegParam"
                    }
                  }
                },
                "description": "Order Details",
                "title": "OrderCommonReplaceItemParam"
              }
            }
          },
          "description": "Order Replace Request Body",
          "title": "OrderCommonReplaceParam"
        }
      }
    }
  },
  "responses": {
    "200": {
      "description": "OK",
      "content": {
        "application/json": {
          "schema": {
            "type": "object",
            "properties": {
              "client_order_id": {
                "type": "string",
                "description": "Client-defined order identifier. Returned in the response for simple orders.<br/> Represents the unique order ID assigned by the user when placing the order for NORMAL order.",
                "example": "0KGOHL4PR2SLC0DKIND4TI0002"
              },
              "client_combo_order_id": {
                "type": "string",
                "description": "Unique client-defined identifier for the combined order.",
                "example": "0KGOHL4PR2SLC0DKIND4TI0002"
              },
              "combo_order_id": {
                "type": "string",
                "description": "Unique System-defined identifier for the combined order.",
                "example": "0KGOHL4PR2SLC0DKIND4TI0002"
              },
              "order_id": {
                "type": "string",
                "description": "System-generated order identifier. Returned in the response for simple orders.<br/> Represents the unique Webull order ID assigned by the system when placing the order for NORMAL order.",
                "example": "80HG7CPSFDPCAL3TP66LKBAS69"
              }
            },
            "title": "OrderCommonWriteResult"
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
    "modify_orders": [
      {
        "client_order_id": "0KGOHL4PR2SLC0DKIND4TI0002",
        "time_in_force": "DAY",
        "stop_price": "11.0",
        "limit_price": "11.0",
        "quantity": "1",
        "order_type": "MARKET",
        "trailing_type": "AMOUNT",
        "trailing_stop_step": "1",
        "target_vol_percent": "10",
        "max_target_percent": "10",
        "algo_start_time": "09:30:00",
        "algo_end_time": "16:00:00",
        "legs": [
          {
            "id": "G2JAJPOR4KUA0F5I9LONH8J83A",
            "quantity": "1"
          }
        ]
      }
    ]
  },
  "postman": {
    "name": "Replace Order",
    "description": {
      "content": "Modifies equity, options and futures orders, including simple orders. For crypto trading, this feature is currently not supported.<br/>• Futures order modification rules:<br/>&nbsp;&nbsp;- For market orders, only `quantity` can be modified.<br/>&nbsp;&nbsp;- For limit orders, only `order_type`, `time_in_force`, `quantity` and `limit_price` can be modified; if modifying `order_type`, it can only be changed to `market`.<br/>&nbsp;&nbsp;- For stop orders, only `order_type`, `time_in_force`, `quantity` and `stop_price` can be modified; if modifying `order_type`, it can only be changed to `market`.<br/>&nbsp;&nbsp;- For stop limit orders, only `order_type`, `time_in_force`, `quantity`, `limit_price` and `stop_price` can be modified; if modifying `order_type`, it can only be changed to `limit`.<br/>&nbsp;&nbsp;- For trailing stop orders, only `trailing_stop_step` can be modified; `order_type` , `trailing_type` and `time_in_force` cannot be modified.",
      "type": "text/plain"
    },
    "url": {
      "path": [
        "trading",
        "orders",
        "replace"
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
