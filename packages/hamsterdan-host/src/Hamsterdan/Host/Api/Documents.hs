-- | The pages FastAPI serves by default for @create_app@ (the OpenAPI 3.1
-- document, Swagger UI, ReDoc, and the OAuth2 redirect helper), byte for
-- byte as the pinned reference (FastAPI 0.141.1) renders them. Generated
-- from the reference; "ApiSpec" checks them against a live reference server.
module Hamsterdan.Host.Api.Documents
  ( openApiDocument
  , swaggerDocument
  , redocDocument
  , oauth2RedirectDocument
  ) where

import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as BC

-- | @GET /openapi.json@ (@application/json@).
openApiDocument :: ByteString
openApiDocument =
  BC.pack
    ( "{\"openapi\":\"3.1.0\",\"info\":{\"title\":\"Hamsterdan host\",\"versio"
        <> "n\":\"0.1.0\"},\"paths\":{\"/healthz\":{\"get\":{\"summary\":\"Health\",\""
        <> "operationId\":\"health_healthz_get\",\"responses\":{\"200\":{\"descr"
        <> "iption\":\"Successful Response\",\"content\":{\"application/json\":"
        <> "{\"schema\":{\"additionalProperties\":true,\"type\":\"object\",\"titl"
        <> "e\":\"Response Health Healthz Get\"}}}}}}},\"/github/webhooks\":{"
        <> "\"post\":{\"summary\":\"Webhook\",\"operationId\":\"webhook_github_we"
        <> "bhooks_post\",\"responses\":{\"202\":{\"description\":\"Successful R"
        <> "esponse\",\"content\":{\"application/json\":{\"schema\":{\"additiona"
        <> "lProperties\":{\"type\":\"string\"},\"type\":\"object\",\"title\":\"Resp"
        <> "onse Webhook Github Webhooks Post\"}}}}}}}}}"
    )

-- | @GET /docs@ (@text/html; charset=utf-8@).
swaggerDocument :: ByteString
swaggerDocument =
  BC.pack
    ( "\n    <!DOCTYPE html>\n    <html>\n    <head>\n    <meta name=\"v"
        <> "iewport\" content=\"width=device-width, initial-scale=1.0\">\n  "
        <> "  <link type=\"text/css\" rel=\"stylesheet\" href=\"https://cdn.j"
        <> "sdelivr.net/npm/swagger-ui-dist@5/swagger-ui.css\">\n    <link"
        <> " rel=\"shortcut icon\" href=\"https://fastapi.tiangolo.com/img/"
        <> "favicon.png\">\n    <title>Hamsterdan host - Swagger UI</title"
        <> ">\n    </head>\n    <body>\n    <div id=\"swagger-ui\">\n    </div"
        <> ">\n    <script src=\"https://cdn.jsdelivr.net/npm/swagger-ui-d"
        <> "ist@5/swagger-ui-bundle.js\"></script>\n    <!-- `SwaggerUIBun"
        <> "dle` is now available on the page -->\n    <script>\n    const"
        <> " ui = SwaggerUIBundle({\n        url: '/openapi.json',\n    \"d"
        <> "om_id\": \"#swagger-ui\",\n\"layout\": \"BaseLayout\",\n\"deepLinking\""
        <> ": true,\n\"showExtensions\": true,\n\"showCommonExtensions\": true"
        <> ",\noauth2RedirectUrl: window.location.origin + '/docs/oauth2-"
        <> "redirect',\n    presets: [\n        SwaggerUIBundle.presets.ap"
        <> "is,\n        SwaggerUIBundle.SwaggerUIStandalonePreset\n      "
        <> "  ],\n    })\n    </script>\n    </body>\n    </html>\n    "
    )

-- | @GET /redoc@ (@text/html; charset=utf-8@).
redocDocument :: ByteString
redocDocument =
  BC.pack
    ( "\n    <!DOCTYPE html>\n    <html>\n    <head>\n    <title>Hamste"
        <> "rdan host - ReDoc</title>\n    <!-- needed for adaptive desig"
        <> "n -->\n    <meta charset=\"utf-8\"/>\n    <meta name=\"viewport\" "
        <> "content=\"width=device-width, initial-scale=1\">\n    \n    <lin"
        <> "k href=\"https://fonts.googleapis.com/css?family=Montserrat:3"
        <> "00,400,700|Roboto:300,400,700\" rel=\"stylesheet\">\n    \n    <l"
        <> "ink rel=\"shortcut icon\" href=\"https://fastapi.tiangolo.com/i"
        <> "mg/favicon.png\">\n    <!--\n    ReDoc doesn't change outer pag"
        <> "e styles\n    -->\n    <style>\n      body {\n        margin: 0;"
        <> "\n        padding: 0;\n      }\n    </style>\n    </head>\n    <b"
        <> "ody>\n    <noscript>\n        ReDoc requires Javascript to fun"
        <> "ction. Please enable it to browse the documentation.\n    </n"
        <> "oscript>\n    <redoc spec-url=\"/openapi.json\"></redoc>\n    <s"
        <> "cript src=\"https://cdn.jsdelivr.net/npm/redoc@2/bundles/redo"
        <> "c.standalone.js\"> </script>\n    </body>\n    </html>\n    "
    )

-- | @GET /docs/oauth2-redirect@ (@text/html; charset=utf-8@).
oauth2RedirectDocument :: ByteString
oauth2RedirectDocument =
  BC.pack
    ( "\n    <!doctype html>\n    <html lang=\"en-US\">\n    <head>\n    "
        <> "    <title>Swagger UI: OAuth2 Redirect</title>\n    </head>\n "
        <> "   <body>\n    <script>\n        'use strict';\n        functio"
        <> "n run () {\n            var oauth2 = window.opener.swaggerUIR"
        <> "edirectOauth2;\n            var sentState = oauth2.state;\n   "
        <> "         var redirectUrl = oauth2.redirectUrl;\n            v"
        <> "ar isValid, qp, arr;\n\n            if (/code|token|error/.tes"
        <> "t(window.location.hash)) {\n                qp = window.locat"
        <> "ion.hash.substring(1).replace('?', '&');\n            } else "
        <> "{\n                qp = location.search.substring(1);\n       "
        <> "     }\n\n            arr = qp.split(\"&\");\n            arr.for"
        <> "Each(function (v,i,_arr) { _arr[i] = '\"' + v.replace('=', '\""
        <> ":\"') + '\"';});\n            qp = qp ? JSON.parse('{' + arr.jo"
        <> "in() + '}',\n                    function (key, value) {\n    "
        <> "                    return key === \"\" ? value : decodeURICom"
        <> "ponent(value);\n                    }\n            ) : {};\n\n  "
        <> "          isValid = qp.state === sentState;\n\n            if "
        <> "((\n              oauth2.auth.schema.get(\"flow\") === \"accessC"
        <> "ode\" ||\n              oauth2.auth.schema.get(\"flow\") === \"au"
        <> "thorizationCode\" ||\n              oauth2.auth.schema.get(\"fl"
        <> "ow\") === \"authorization_code\"\n            ) && !oauth2.auth."
        <> "code) {\n                if (!isValid) {\n                    "
        <> "oauth2.errCb({\n                        authId: oauth2.auth.n"
        <> "ame,\n                        source: \"auth\",\n               "
        <> "         level: \"warning\",\n                        message: "
        <> "\"Authorization may be unsafe, passed state was changed in se"
        <> "rver. The passed state wasn't returned from auth server.\"\n  "
        <> "                  });\n                }\n\n                if "
        <> "(qp.code) {\n                    delete oauth2.state;\n       "
        <> "             oauth2.auth.code = qp.code;\n                   "
        <> " oauth2.callback({auth: oauth2.auth, redirectUrl: redirectUr"
        <> "l});\n                } else {\n                    let oauthE"
        <> "rrorMsg;\n                    if (qp.error) {\n               "
        <> "         oauthErrorMsg = \"[\"+qp.error+\"]: \" +\n              "
        <> "              (qp.error_description ? qp.error_description+ "
        <> "\". \" : \"no accessCode received from the server. \") +\n       "
        <> "                     (qp.error_uri ? \"More info: \"+qp.error_"
        <> "uri : \"\");\n                    }\n\n                    oauth2"
        <> ".errCb({\n                        authId: oauth2.auth.name,\n "
        <> "                       source: \"auth\",\n                     "
        <> "   level: \"error\",\n                        message: oauthErr"
        <> "orMsg || \"[Authorization failed]: no accessCode received fro"
        <> "m the server.\"\n                    });\n                }\n   "
        <> "         } else {\n                oauth2.callback({auth: oau"
        <> "th2.auth, token: qp, isValid: isValid, redirectUrl: redirect"
        <> "Url});\n            }\n            window.close();\n        }\n\n"
        <> "        if (document.readyState !== 'loading') {\n           "
        <> " run();\n        } else {\n            document.addEventListen"
        <> "er('DOMContentLoaded', function () {\n                run();\n"
        <> "            });\n        }\n    </script>\n    </body>\n    </ht"
        <> "ml>\n        "
    )
