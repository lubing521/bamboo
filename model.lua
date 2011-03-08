
module(..., package.seeall)

local db = BAMBOO_DB
local model_counter = 0;

------------------------------------------------------------------------
-- 数据库检索的限制函数集
-- 由于使用的时候希望不再做导入工作，所以在加载Model模块的时候直接导入到全局环境中
------------------------------------------------------------------------

_G['lt'] = function (limitation)
	return function (v)
		if v < limitation then
			return true
		else
			return false
		end
	end
end

_G['gt'] = function (limitation)
	return function (v)
		if v > limitation then
			return true
		else
			return false
		end
	end
end


_G['le'] = function (limitation)
	return function (v)
		if v <= limitation then
			return true
		else
			return false
		end
	end
end

_G['ge'] = function (limitation)
	return function (v)
		if v >= limitation then
			return true
		else
			return false
		end
	end
end

_G['bt'] = function (small, big)
	return function (v)
		if v > small and v < big then
			return true
		else
			return false
		end
	end
end

_G['be'] = function (small, big)
	return function (v)
		if v >= small and v < big then
			return true
		else
			return false
		end
	end
end

_G['outside'] = function (small, big)
	return function (v)
		if v < small and v > big then
			return true
		else
			return false
		end
	end
end

_G['contains'] = function (substr)
	return function (v)
		if v:contains(substr) then 
			return true
		else
			return false
		end
	end
end

_G['startsWith'] = function (substr)
	return function (v)
		if v:startsWith(substr) then 
			return true
		else
			return false
		end
	end
end

_G['endsWith'] = function (substr)
	return function (v)
		if v:endsWith(substr) then 
			return true
		else
			return false
		end
	end
end

------------------------------------------------------------------------
-- Model定义
-- Model是Bambo中涉及到数据库及模型定义的通用接口
------------------------------------------------------------------------
local Model = Object:extend {
	__tag = 'Bamboo.Model';
	-- __name和__tag的最后一个单词不一定要保持一致
	__name = 'Model';
    -- nothing to do
	init = function (self)
		self.id = self:getCounter() + 1
		return self 
	end;
    
    -- 在数据库中创建一个hash表项，保存模型实例
    save = function (self)
        local model_key = self.__name + ':' + tostring(self.id)
		-- 如果之前数据库中没有这个对象，即是新创建的情况
		if not db:hget(model_key, 'id') then
			-- 对象类别的总数计数器就加1
			db:incr(self.__name + ':__counter')
		end

		for k, v in pairs(self) do
			-- 保存的时候序列化一下。跟Django一样，每一个save时，
			-- 所有字段都全部保存，包括id
			-- 只保存正常数据，不保存函数和继承自父类的私有属性
			if not k:startsWith('_') and type(v) ~= 'function' then
				db:hset(model_key, k, seri(v))
			end
		end
		
        return true
    end;
    
    -- 
    saveName = function (self)
		local model_key = self.__name + ':' + self.name
		-- 如果之前数据库中没有这个对象，即是新创建的情况
		if not db:exists(model_key) then
			-- 确保只有在这个key值不存在的情况下才写
			db:setnx(model_key, tostring(self.id))
		end
		return true
    end;
    
    -- 类函数。由类对象访问
    getNameIndex = function (self, name)
		local model_key = self.__name + ':' + name
		local index = db:get(model_key)
		if not index then
			-- 如果不存在NameIndex，就返回nil, 以示区别
			return nil
		end
		
		return index
    end;
	-- 类函数。由类对象访问
	getById = function (self, id)
		local obj = self()
		local model_key = self.__name + ':' + tostring(id)
		local data = db:hgetall(model_key)
		table.update(obj, data)
		return obj
	end;
	-- 类函数。由类对象访问
	-- 返回实例对象，此对象的数据由数据库中的数据更新
	getByName = function (self, name)
		local data
		local obj = self()
		local model_key = self.__name + ':' + tostring(name)
		
		local id = db:get(model_key) 
		if not id then
			data = db:hgetall(model_key) 
		else
			model_idkey = self.__name + ':' + tostring(id)
			data = db:hgetall(model_idkey)
			-- 注意，这里要判断是否获取到了值，返回值有可能是一张空表 
		end
		
		table.update(obj, data)
		return obj
	end;
	
	-- 返回此类中所有的成员
	all = function (self)
		local all_instaces = {}
		local all_keys = db:keys(self.__name + ':*')
		for _, key in ipairs(all_keys) do
			table.insert(all_instaces, db:hgetall(key))
		end
		return all_instaces
	end;
	
    -- 返回第一个查询对象，
    get = function (self, query)
		local query_args = table.copy(query)
		local id = query_args.id
		
		-- 如果查询要求中有id，就以id为主键查询。因为id是存放在总key中，所以要分开处理
		if id then
			local vv = nil
			query_args['id'] = nil
			local query_key = self.__name + ':' + tonumber(id)
			-- 判断数据库中有无此key存在
			local flag = db:exists(query_key)
			if not flag then return nil end
			-- 把这个key下的内容整个取出来
			vv = db:hgetall(query_key)
			
			for k, v in pairs(query_args) do
				if not vv[k] then return nil end
				-- 如果是函数，执行限定比较，返回布尔值
				if type(v) == 'function' then
					-- 进入函数v进行比较的，总是单个字段
					local flag = v(vv)
					-- 如果不在限制条件内，直接跳出循环
					if not flag then return nil end
				-- 处理查询条件为等于的情况
				else
					-- 一旦发现有不等的情况，立即返回否值
					if vv[k] ~= v then return nil end
				end
			end
			-- 如果执行到这一步，就说明已经找到了，返回对象
			return vv
		-- 如果查询要求中没有id
		else
			-- 取得所有关于这个模型的实例keys
			local all_keys = db:keys(self.__name + ':*')
			for _, kk in ipairs(all_keys) do
				-- 根据key获得一个实例的内容，返回一个表
				local vv = db:hgetall(kk)
				local flag = true
				for k, v in pairs(query_args) do
					if not vv[k] then flag=false; break end
					-- 目前为止，还只能处理条件式为等于的情况
					if type(v) == 'function' then
						-- 进入函数v进行比较的，总是单个字段
						flag = v(vv)
						-- 如果不在限制条件内，直接跳出循环
						if not flag then break end
					-- 处理条件式为等于的情况
					else
						if vv[k] ~= v then flag=false; break end
					end
				end
				-- 如果走到这一步，flag还为真，则说明已经找到第一个，直接返回
				if flag then
					return vv
				end
			end
		end
		
    end;

	-- filter的query表中，不应该出现id，这里也不打算支持它
	-- filter返回的是一个列表
	filter = function (self, query)
		local query_args = table.copy(query)
		if query_args['id'] then query_args['id'] = nil end
		-- ???行不行???
		-- 这里让query_set（一个表）也获得Model中定义的方法，到时可用于链式操作
		local query_set = setProto({}, Model)
	
		-- 取得所有关于这个模型的实例keys
		local all_keys = db:keys(self.__name + ':*')
		for _, kk in ipairs(all_keys) do
			-- 根据key获得一个实例的内容，返回一个表
			local vv = db:hgetall(kk)
			local flag = true	
			for k, v in pairs(query_args) do
				-- 对于多余的查询条件，一经发现，直接跳出
				if not vv[k] then flag=false; break end
				-- 处理条件式为外调函数的情况
				if type(v) == 'function' then
					-- 进入函数v进行比较的，总是单个字段
					flag = v(vv)
					-- 如果不在限制条件内，直接跳出循环
					if not flag then break end
				-- 处理条件式为等于的情况
				else
					if vv[k] ~= v then flag=false; break end
				end
			end
			-- 如果走到这一步，flag还为真，则说明已经找到，添加到查询结果表中去
			if flag then
				-- filter返回的表中由一个个值对构成
				table.insert(query_set, vv)
			end
		end
		return query_set
	end;

    del = function (self)
		local model_name = self.__name
		-- 如果self是单个对象
		if self['id'] then
			-- 在数据库中删除这个对象的内容
			db:del(model_name + ':' + self.id)
			self = nil
		-- 如果self是一个对象列表
		else
			-- 一个一个挨着删除
			for _, v in ipairs(self) do
				db:del(model_name + ':' + v.id)
			end
		end
		return true
    end;
    
    getCounter = function (self)
		local model_name = self.__name
		return tonumber(db:get(model_name + ':__counter') or 0)
    end;

}

return Model
