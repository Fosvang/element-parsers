defmodule Parser do
  use Platform.Parsing.Behaviour
  require Logger

  # ELEMENT IoT Parser for Adeunis ARF8170BA
  # According to documentation provided by Adeunis
  # Link: https://www.adeunis.com/en/produit/dry-contacts-2/
  # Documentation: https://www.adeunis.com/wp-content/uploads/2017/08/DRY_CONTACTS_LoRaWAN_UG_V2.0.0_FR_GB.pdf
  #
  # parser for 4 counter inputs, outputs are not interpreted
  #
  # Changelog:
  #   2019-xx-xx [jb]: Initial implementation.
  #   2019-09-06 [jb]: Added parsing catchall for unknown payloads.
  #

  def parse(<<code::8, status::8, payload::binary>>, _meta) do
    << _fcnt::3, _res::1, err::4 >> = << status::8 >>

    error = case err do
      0 -> "no error"
      1 -> "config done"
      2 -> "low battery"
      4 -> "config switch error"
      8 -> "HW error"
      _ -> "unknown"
    end

    case code do
      0x10 ->
        << s300::8, s301::8, _s320::8, _s321::8, _s322::8, _s323::8, _s306::8 >> = payload
        %{
          frame_type: "configuration",
          keepalive_time: s300/6,
          transmission_period: s301/6,
          error: error,
        }

      0x20 ->
        << adr1::8, mode1::8 >> = payload
        adr = case adr1 do
          0 -> "Off"
          1 -> "On"
        end
       mode = case mode1 do
          0 -> "ABP"
          1 -> "OTAA"
        end
        %{
          frame_type: "ADR config",
          ADR: adr,
          Mode: mode,
          error: error,
        }

      0x30 ->
        %{
          frame_type: "Status frame",
          status: "Online",
          error: error,
        }

      0x40 ->
        << tor1::16, tor2::16, tor3::16, tor4::16, _details::8 >> = payload
        %{
          frame_type: "data frame",
          Port1_count: tor1,
          Port2_count: tor2,
          Port3_count: tor3,
          Port4_count: tor4,
          error: error,
        }
      _ ->
        []
    end

  end
  def parse(payload, meta) do
    Logger.warn("Could not parse payload #{inspect payload} with frame_port #{inspect get_in(meta, [:meta, :frame_port])}")
    []
  end
end
