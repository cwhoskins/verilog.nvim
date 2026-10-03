module parameterized #(
    parameter int WIDTH = 8,
    parameter int DEPTH = 16
) (
    input  logic              clk,
    input  logic [WIDTH-1:0]  data_in,
    output logic [WIDTH-1:0]  data_out
);
endmodule
