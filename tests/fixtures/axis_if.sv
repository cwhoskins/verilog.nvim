interface axis_if;
    logic [31:0] data;
    logic        vld;
    logic        rdy;

    modport m(output data, vld, input rdy);
    modport s(input data, vld, output rdy);
endinterface
