import C4.DispatchModel: last_n

@testset "Check generating earlier time indices" begin
    @test last_n(5, 3, 10) == [3, 4, 5]
    @test last_n(1, 5, 10) == [7, 8, 9, 10, 1]
    @test last_n(10, 1, 10) == [10]
end
