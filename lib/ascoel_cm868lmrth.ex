defmodule Parser do
  use Platform.Parsing.Behaviour
  require Logger

  # ELEMENT IoT Parser for Ascoel CM868LRTH sensor. Magnetic door/window sensor + temperature and humidity
  # According to documentation provided by Ascoel
  #
  # Changelog:
  #   2019-xx-xx [jb]: Initial implementation.
  #   2019-09-06 [jb]: Added parsing catchall for unknown payloads.
  #

  def parse(<<evt::8, count::16, temp::float-little-32, hum::float-little-32>>, %{meta: %{frame_port: 30 }}) do
    << _res::3, _ins::2, blow::1, tamper::1, intr::1>> = << evt::8 >>

    <<counter::integer>>=<<count::integer>>

    %{
      messagetype: "event",
      intrusion: intr,
      tamper: tamper,
      batterywarn: blow,
      counter: counter,
      temperature: temp,
      humidity: hum
    }
  end

  def parse(<< _bat_t::1, bat_p::7, evt::8, temp::float-little-32, hum::float-little-32>>, %{meta: %{frame_port: 9 }}) do
    << _res::3, _ins::2, blow::1, tamper::1, intr::1>> = << evt::8 >>

    %{
      messagetype: "status",
      battery: bat_p,
      intrusion: intr,
      tamper: tamper,
      batterywarn: blow,
      temperature: temp,
      humidity: hum
    }
  end

  def parse(payload, meta) do
    Logger.warn("Could not parse payload #{inspect payload} with frame_port #{inspect get_in(meta, [:meta, :frame_port])}")
    []
  end

  def fields do
    [
      %{
        "field" => "counter",
        "display" => "Openings",
      },
      %{
        "field" => "temperature",
        "display" => "Temperature",
        "unit" => "°C"
      },
      %{
        "field" => "humidity",
        "display" => "Humidity",
        "unit" => "%"
      }
    ]
  end

  def tests() do
    [
      {
        :parse_hex, "01000A61F2C341A0661542", %{meta: %{frame_port: 30}}, %{
          messagetype: "event",
          intrusion: 1,
          tamper: 0,
          batterywarn: 0,
          counter: 10,
          temperature: 24.493349075317383,
          humidity: 37.3502197265625
        }
      },
      {
        :parse_hex, "E400600EBF4180D70A42", %{meta: %{frame_port: 9}}, %{
          messagetype: "status",
          intrusion: 0,
          tamper: 0,
          battery: 100,
          batterywarn: 0,
          temperature: 23.88201904296875,
          humidity: 34.71044921875
        }
      }
    ]
  end
end
