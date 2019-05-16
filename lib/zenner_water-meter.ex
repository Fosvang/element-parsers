defmodule Parser do
  use Platform.Parsing.Behaviour

  require Logger

  # ELEMENT IoT Parser for ZENNER Water meters
  # According to documentation provided by ZENNER International
  # Link:  https://www.zenner.com
  #
  # Changelog:
  #   2018-04-26 [jb]: Added fields(), tests() and value_m3
  #   2019-05-15 [gw]: Added support for SP12.
  #

  def fields() do
    [
      %{
        field: "value_m3",
        display: "Volume",
        unit: "m3",
      },
      %{
        field: "value",
        display: "Liter",
        unit: "l",
      },
    ]
  end

  def parse(<<type::integer-4, subtype::integer-4, rest::binary>>, _meta) do
    case type do
      1 ->
        value = parse_subtype(subtype, rest)
        create_values_result(value)

      2 ->
        case rest do
          <<_::binary-2, month::binary-4>> ->
            value = parse_subtype(subtype, month)
            create_values_result(value)

          _ ->
            []
        end

      5 ->
        case rest do
          <<ch1::binary-4, ch2::binary-4, _status::binary-2>> ->
            value_1 = parse_subtype(subtype, ch1)
            value_2 = parse_subtype(subtype, ch2)
            create_values_result(value_1, value_2)

          _ ->
            []
        end

      6 ->
        case rest do
          <<_::binary-2, ch1::binary-4, ch2::binary-4>> ->
            value_1 = parse_subtype(subtype, ch1)
            value_2 = parse_subtype(subtype, ch2)
            create_values_result(value_1, value_2)

          _ ->
            []
        end

      12 ->
        case rest do
          <<channel, first_hour, first_hour_value::binary-4, second_hour_value::binary-4,
            third_hour_value::binary-4, _rfu::binary-2>> ->
            value_1 = parse_subtype(subtype, first_hour_value)
            value_2 = parse_subtype(subtype, second_hour_value)
            value_3 = parse_subtype(subtype, third_hour_value)

            %{
              channel: channel,
              first_hour: first_hour,
            }
            |> Map.merge(create_values_result(value_1, value_2, value_3))

          _ ->
            []
        end

      type ->
        Logger.error("SP #{inspect(type)} is not yet implemented.")
        []
    end
  end

  defp create_values_result(value) do
    %{
      value: value,
      value_m3: value / 1000,
    }
  end
  defp create_values_result(value_1, value_2) do
    %{
      value_1: value_1,
      value_1_m3: value_1 / 1000,
      value_2: value_2,
      value_2_m3: value_2 / 1000,
    }
  end
  defp create_values_result(value_1, value_2, value_3) do
    %{
      value_3: value_3,
      value_3_m3: value_3 / 1000,
    }
    |> Map.merge(create_values_result(value_1, value_2))
  end

  def parse_subtype(subtype, <<data::binary-4>>) do
    case subtype do
      0 ->
        parse_bcd(data, 0)

      1 ->
        <<int::little-integer-32>> = data
        int

      2 ->
        <<int::little-integer-32>> = data
        int

      _ ->
        0
    end
  end
  def parse_subtype(_, _), do: 0

  def parse_bcd(<<num::integer-4, rest::bitstring>>, acc) do
    parse_bcd(rest, num + 10 * acc)
  end
  def parse_bcd("", acc), do: acc

  def tests() do
    [
      {:parse_hex, "112C000000", %{}, %{value: 44, value_m3: 0.044}},
      {:parse_hex, "11FC010000", %{}, %{value: 508, value_m3: 0.508}},
      {:parse_hex, "111E000000", %{}, %{value: 30, value_m3: 0.03}},

      # SP 12
      {
        :parse_hex, "C000167B0000007B0000007B0000000000", %{}, %{}
      },

      # TODO: Implement: 9132015624000000000000
      # TODO: Implement: 9219001701010001100005CE4B92000000
    ]
  end

end
