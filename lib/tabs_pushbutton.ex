defmodule Parser do
  use Platform.Parsing.Behaviour
  require Logger

  # !!! This Parser is not maintained anymore. Use tabs.ex instead !!!
  #
  # ELEMENT IoT Parser for TrackNet Tabs Push Button
  # According to documentation provided by TrackNet
  # Payload Description Version v1.3 and v1.4

  # Changelog
  #   2018-08-14 [as]: added v1.4 functionality
  #   2019-04-04 [gw]: formatted code, corrected name of device in comment, added frameport to tests


  def parse(<<status, battery, temp, time::little-16, count::little-24, rest::binary>>, _meta) do
    <<_rfu::6, state_1::1, state_0::1>> = <<status>>
    <<rem_cap::4, voltage::4>> = <<battery>>
    <<_rfu::1, temperature::7>> = <<temp>>

    button_1 = case state_1 do
      0 -> "not pushed"
      1 -> "pushed"
    end

    button_0 = case state_0 do
      0 -> "not pushed"
      1 -> "pushed"
    end

    result = %{
      button_1_state: button_1,
      button_0_state: button_0,
      battery_state: 100*(rem_cap/15),
      battery_voltage: (25+voltage)/10,
      temperature: temperature-32,
      time_elapsed_since_trigger: time,
      total_count: count
    }

    # additional functionality for v1.4
    case rest do
      <<count_1::little-24>> ->
        Map.merge(result, %{
          total_count: count+count_1,
          button_0_count: count,
          button_1_count: count_1
        })
        _ -> result
    end
  end
  def parse(payload, meta) do
    Logger.warn("Could not parse payload #{inspect payload} with frame_port #{inspect get_in(meta, [:meta, :frame_port])}")
    []
  end

  def fields do
    [
      %{
        "field" => "battery_state",
        "display" => "Battery state",
        "unit" => "%"
      },
      %{
        "field" => "battery_voltage",
        "display" => "Battery voltage",
        "unit" => "V"
      },
      %{
        "field" => "temperature",
        "display" => "Temperature",
        "unit" => "°C"
      },
      %{
        "field" => "total_count",
        "display" => "Counter total"
      },
      %{
        "field" => "button_0_count",
        "display" => "Counter Button 0"
      },
      %{
        "field" => "button_1_count",
        "display" => "Counter Button 1"
      }
    ]
  end

  # Test case and data for automatic testing
  def tests() do
    [
      {
        :parse_hex, "01FE39EA000C0000000000", %{meta: %{frame_port: 147}}, %{
          total_count: 12,
          time_elapsed_since_trigger: 234,
          button_1_state: "not pushed",
          button_1_count: 0,
          button_0_state: "pushed",
          button_0_count: 12,
          battery_voltage: 3.9,
          battery_state: 100.0,
          temperature: 25
        }
      },
      {
        :parse_hex, "01FE39EA000C0000", %{meta: %{frame_port: 147}}, %{
          total_count: 12,
          time_elapsed_since_trigger: 234,
          button_1_state: "not pushed",
          button_0_state: "pushed",
          battery_voltage: 3.9,
          battery_state: 100.0,
          temperature: 25
        }
      },
    ]
  end

end
