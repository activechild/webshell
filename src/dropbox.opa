// license: AGPL
// (c) MLstate, 2012
// author: Adam Koprowski

import stdlib.apis.dropbox
import stdlib.web.client

database Dropbox.conf /dropbox_config

 // TODO? could the generic OAuth authentication be bundled in that module?
 //       only providing a single simple function?
type Dropbox.credentials = {no_credentials}
                        or {string request_secret, string request_token}
                        or {Dropbox.creds authenticated}

module DropboxConnect {

  private server config =
    _ = CommandLine.filter(
      { init: void
      , parsers: [{ CommandLine.default_parser with
          names: ["--dropbox-config"],
          param_doc: "APP_KEY,APP_SECRET",
          description: "Sets the application data for the associated Dropbox application",
          function on_param(state) {
            parser {
              case app_key=Rule.alphanum_string [,] app_secret=Rule.alphanum_string :
              {
                /dropbox_config <- ~{app_key, app_secret}
                {no_params: state}
              }
            }
          }
        }]
      , anonymous: []
      , title: "Dropbox configuration"
      }
    )
    match (?/dropbox_config) {
      case {some: config}: config
      default:
        Log.error("webshell[config]", "Cannot read Dropbox configuration (application key and/or secret key)
Please re-run your application with: --dropbox-config option")
        System.exit(1)
    }

  private DB = Dropbox(config)

  private redirect = "http://{Config.host}/connect/dropbox"

  function login(executor)(raw_token) {
    function connect(auth_data) {
      Log.info("Dropbox", "connection data: {raw_token}")
      authentication_failed = {no_credentials}
      match (auth_data) {
      case ~{request_secret, request_token}:
        match (DB.OAuth.connection_result(raw_token)) {
        case {success: s}:
          if (s.token == request_token) {
            match (DB.OAuth.get_access_token(s.token, request_secret, s.verifier)) {
            case {success: s}:
              dropbox_creds = {token: s.token, secret: s.secret}
              Log.info("Dropbox", "got credentials: {dropbox_creds}")
              {authenticated: dropbox_creds}
            default:
              authentication_failed
            }
          } else
            authentication_failed
        default:
          authentication_failed
        }
      default:
        authentication_failed
      }
    }
    executor(connect)
  }

  private function authenticate() {
    token = DB.OAuth.get_request_token(redirect)
    Log.info("Dropbox", "Obtained request token {token}")
    match (token) {
    case {success: token}:
      auth_url = DB.OAuth.build_authorize_url(token.token, redirect)
      auth_state = {request_secret: token.secret, request_token: token.token}
      { response: {redirect: auth_url},
        state_change: {new_state: auth_state}
      }
    default:
      Service.respond_with(<>Dropbox authorization failed</>)
    }
  }

  private function pad(length, s) {
    String.pad_left(" ", length, s)
  }

  private date_printer = Date.generate_printer("%Y-%m-%d %k:%M")

  private function show_element(Dropbox.element element) {
    info =
      match (element) {
      case {file, ~metadata, ...}: metadata
      case {folder, ~metadata, ...}: metadata
      }
    size = "{info.size}"
    modification = Option.map(Date.to_formatted_string(date_printer, _), info.modified) ? ""
    name = info.path
    <pre>{size |> pad(10, _)}   {modification |> pad(16, _)}   {name}</>
  }

  private function files_to_xhtml(files) {
    <>{List.map(show_element, files)}</>
  }

  function ls(creds) {
    match (creds) {
    case {authenticated: creds}:
      db_files = DB.Files("dropbox", "/").metadata(DB.default_metadata_options, creds)
      response =
        match (db_files) {
        case {success: {~contents, ...}}: files_to_xhtml(contents ? [])
        default: <>Dropbox connection failed</>
        }
      Service.respond_with(response)
    default:
      authenticate()
    }
  }

  Service.spec spec =
    { initial_state: Dropbox.credentials {no_credentials},
      function parse_cmd(creds) {
        parser {
        case "ls": ls(creds)
        }
      }
    }

}
