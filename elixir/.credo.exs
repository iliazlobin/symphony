%{
  configs: [
    %{
      name: "default",
      # Parse the complete LiveView integration suite on busy developer machines.
      parse_timeout: 30_000
    }
  ]
}
