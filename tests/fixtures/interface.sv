interface my_bus #(parameter WIDTH = 8) (input clk);
    logic [WIDTH-1:0] data;
    logic             valid;
    logic             ready;
endinterface
